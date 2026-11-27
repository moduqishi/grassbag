/**
 * GrassBag Local Android PTY Bridge (`pty-bridge.mjs`)
 * Spawns an interactive shell inside a real POSIX PTY (via node-pty) with automatic
 * child_process fallback, cross-chunk resize/signal framing with ESC flush timer (never
 * swallows standalone Esc in Vim/less/fzf/TUI!), and clean process-group teardown.
 *
 * Out-of-band control sequences on stdin:
 * - Resize: ESC ] 777 ; gbresize ; <cols> ; <rows> BEL
 * - Signal: ESC ] 777 ; gbsignal ; <SIGINT|SIGTERM> BEL
 *
 * Startup handshake on stdout (stripped by Android native reader):
 * - ESC ] 777 ; gbmode ; pty BEL   (real POSIX PTY active)
 * - ESC ] 777 ; gbmode ; pipe BEL  (fallback pipe mode active)
 */
import { createRequire } from 'node:module';
import { spawn as cpSpawn } from 'node:child_process';

const shell = process.argv[2] || '/bin/bash';
const cwd = process.argv[3] || '/root/workspace';
const initCols = Math.max(20, Math.min(400, Number(process.argv[4]) || 80));
const initRows = Math.max(8, Math.min(200, Number(process.argv[5]) || 24));

const CTRL_RE = /\x1b\]777;(gbresize|gbsignal);([^\x07]+)\x07/g;
const PREFIX_RESIZE = '\x1b]777;gbresize;';
const PREFIX_SIGNAL = '\x1b]777;gbsignal;';

/**
 * Stateful cross-chunk scanner with a 25ms flush timer so:
 * 1) Split OSC 777 control sequences never leak into the shell
 * 2) Standalone `Esc` (`\x1b`) keypresses flush within 25ms instead of hanging forever!
 */
function createControlStripper({ onResize, onSignal, onFlushData }) {
  let pending = '';
  let flushTimer = null;

  const clearTimer = () => {
    if (flushTimer) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
  };

  const couldBeControlPrefix = (tail) => {
    if (!tail || tail.includes('\x07') || tail.length >= 48) return false;
    return (
      PREFIX_RESIZE.startsWith(tail) ||
      tail.startsWith(PREFIX_RESIZE) ||
      PREFIX_SIGNAL.startsWith(tail) ||
      tail.startsWith(PREFIX_SIGNAL)
    );
  };

  return (chunkStr) => {
    clearTimer();
    const combined = pending + chunkStr;
    pending = '';

    const lastEsc = combined.lastIndexOf('\x1b');
    let body = combined;
    if (lastEsc >= 0) {
      const tail = combined.slice(lastEsc);
      if (couldBeControlPrefix(tail)) {
        body = combined.slice(0, lastEsc);
        pending = tail;
        flushTimer = setTimeout(() => {
          flushTimer = null;
          if (pending.length > 0) {
            const toFlush = pending;
            pending = '';
            onFlushData(toFlush);
          }
        }, 25);
        flushTimer.unref?.();
      }
    }

    let out = '';
    let lastIdx = 0;
    CTRL_RE.lastIndex = 0;
    let m;
    while ((m = CTRL_RE.exec(body)) !== null) {
      if (m.index > lastIdx) out += body.slice(lastIdx, m.index);
      const kind = m[1];
      const arg = m[2];
      if (kind === 'gbresize') {
        const parts = arg.split(';');
        const cols = Math.max(20, Math.min(400, parseInt(parts[0], 10) || 80));
        const rows = Math.max(8, Math.min(200, parseInt(parts[1], 10) || 24));
        onResize(cols, rows);
      } else if (kind === 'gbsignal') {
        onSignal(arg.trim());
      }
      lastIdx = CTRL_RE.lastIndex;
    }
    if (lastIdx < body.length) out += body.slice(lastIdx);
    return out;
  };
}

let ptyMod = null;
try {
  const req = createRequire('/opt/dsh-slots/current/package.json');
  ptyMod = req('node-pty');
} catch {
  ptyMod = null;
}

let term = null;
if (ptyMod && typeof ptyMod.spawn === 'function') {
  try {
    term = ptyMod.spawn(shell, ['-i'], {
      name: process.env.TERM || 'xterm-256color',
      cols: initCols,
      rows: initRows,
      cwd,
      env: process.env,
    });
  } catch {
    term = null;
  }
}

if (term) {
  try { process.stdout.write('\x1b]777;gbmode;pty\x07'); } catch {}

  const cleanupPty = () => {
    const pid = typeof term.pid === 'number' && term.pid > 1 ? term.pid : null;
    try {
      if (pid) process.kill(-pid, 'SIGHUP');
    } catch {}
    try { term.kill('SIGHUP'); } catch {}
    try { term.kill('SIGTERM'); } catch {}
    if (pid) {
      setTimeout(() => {
        try { process.kill(-pid, 'SIGKILL'); } catch {}
      }, 90).unref?.();
    }
  };

  term.onData((data) => {
    try { process.stdout.write(data); } catch {}
  });
  term.onExit(({ exitCode }) => {
    process.exit(typeof exitCode === 'number' ? exitCode : 0);
  });

  const strip = createControlStripper({
    onResize: (c, r) => {
      try { term.resize(c, r); } catch {}
    },
    onSignal: (sig) => {
      if (sig === 'SIGINT') {
        try { term.write('\x03'); } catch {}
      } else {
        const safeSig = sig === 'SIGTERM' || sig === 'SIGKILL' ? sig : 'SIGINT';
        try {
          if (typeof term.pid === 'number' && term.pid > 1) process.kill(-term.pid, safeSig);
        } catch {}
      }
    },
    onFlushData: (data) => {
      try { term.write(data); } catch {}
    },
  });

  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    const clean = strip(String(chunk));
    if (clean.length > 0) {
      try { term.write(clean); } catch {}
    }
  });
  process.stdin.on('end', () => {
    cleanupPty();
    setTimeout(() => process.exit(0), 130).unref?.();
  });
  process.on('SIGTERM', () => { cleanupPty(); setTimeout(() => process.exit(0), 120).unref?.(); });
  process.on('SIGHUP', () => { cleanupPty(); setTimeout(() => process.exit(0), 120).unref?.(); });
  process.on('SIGINT', () => { cleanupPty(); setTimeout(() => process.exit(0), 120).unref?.(); });
} else {
  try { process.stdout.write('\x1b]777;gbmode;pipe\x07'); } catch {}

  const child = cpSpawn(shell, ['-i'], {
    cwd,
    env: process.env,
    detached: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const cleanupChild = () => {
    const pid = typeof child.pid === 'number' && child.pid > 1 ? child.pid : null;
    try { child.stdin.end(); } catch {}
    try {
      if (pid) process.kill(-pid, 'SIGHUP');
    } catch {}
    try { child.kill('SIGTERM'); } catch {}
    if (pid) {
      setTimeout(() => {
        try { process.kill(-pid, 'SIGKILL'); } catch {}
        try { child.kill('SIGKILL'); } catch {}
      }, 90).unref?.();
    }
  };
  child.stdout.on('data', (d) => {
    try { process.stdout.write(d); } catch {}
  });
  child.stderr.on('data', (d) => {
    try { process.stdout.write(d); } catch {}
  });
  child.on('close', (code) => process.exit(code ?? 0));

  const strip = createControlStripper({
    onResize: () => {},
    onSignal: (sig) => {
      const safeSig = sig === 'SIGTERM' || sig === 'SIGKILL' ? sig : 'SIGINT';
      try {
        if (typeof child.pid === 'number' && child.pid > 1) {
          process.kill(-child.pid, safeSig);
          return;
        }
      } catch {}
      try { child.kill(safeSig); } catch {}
    },
    onFlushData: (data) => {
      if (child.stdin.writable) {
        try { child.stdin.write(data); } catch {}
      }
    },
  });
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    const clean = strip(String(chunk));
    if (clean.length > 0 && child.stdin.writable) {
      child.stdin.write(clean);
    }
  });
  process.stdin.on('end', () => {
    cleanupChild();
    setTimeout(() => process.exit(0), 130).unref?.();
  });
  process.on('SIGTERM', () => { cleanupChild(); setTimeout(() => process.exit(0), 120).unref?.(); });
  process.on('SIGHUP', () => { cleanupChild(); setTimeout(() => process.exit(0), 120).unref?.(); });
  process.on('SIGINT', () => { cleanupChild(); setTimeout(() => process.exit(0), 120).unref?.(); });
}
