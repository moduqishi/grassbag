#!/usr/bin/env node
/**
 * Shared client for GrassBag `droid-*` CLI commands.
 * Communicates strictly over Android private 0600 UDS (`DROID_BRIDGE_SOCKET`)
 * with per-boot Bearer token (`DROID_BRIDGE_TOKEN`).
 */
import { request } from 'node:http';

const socketPath = process.env.DROID_BRIDGE_SOCKET;
const token = process.env.DROID_BRIDGE_TOKEN;
const action = process.argv[2];

if (!socketPath || !token) {
  console.error('droid-rpc: DROID_BRIDGE_SOCKET and DROID_BRIDGE_TOKEN must be set');
  process.exit(2);
}

const STDIN_ACTIONS = new Set(['clip', 'notify', 'share', 'tts']);
const MAX_STDIN_BYTES = 512 * 1024;
const STDIN_IDLE_TIMEOUT_MS = 250;

function readStdinIfPiped(shouldRead) {
  if (!shouldRead || process.stdin.isTTY) return Promise.resolve('');
  return new Promise((resolve) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    let sawData = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(idleTimer);
      process.stdin.removeListener('data', onData);
      process.stdin.removeListener('end', finish);
      process.stdin.removeListener('error', finish);
      process.stdin.pause();
      resolve(Buffer.concat(chunks, total).toString('utf8'));
    };
    const onData = (chunk) => {
      sawData = true;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = MAX_STDIN_BYTES - total;
      if (remaining <= 0) {
        finish();
        return;
      }
      const slice = buf.length > remaining ? buf.subarray(0, remaining) : buf;
      chunks.push(slice);
      total += slice.length;
      if (total >= MAX_STDIN_BYTES) finish();
    };
    // Guard against non-TTY subshells keeping stdin open with no data (e.g. `droid-clip` read mode in tool exec).
    const idleTimer = setTimeout(() => {
      if (!sawData) finish();
    }, STDIN_IDLE_TIMEOUT_MS);
    idleTimer.unref?.();
    process.stdin.on('data', onData);
    process.stdin.once('end', finish);
    process.stdin.once('error', finish);
    process.stdin.resume();
  });
}

const args = process.argv.slice(3);
const needsStdin = STDIN_ACTIONS.has(action) && (args.length === 0 || (action === 'notify' && args.length < 2));
const stdinText = await readStdinIfPiped(needsStdin);
const body = JSON.stringify({ action, args, stdin: stdinText });

const req = request(
  {
    socketPath,
    path: '/v1/droid',
    method: 'POST',
    timeout: 10_000,
    headers: {
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
      authorization: `Bearer ${token}`,
    },
  },
  (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      try {
        const json = JSON.parse(text || '{}');
        if (res.statusCode >= 200 && res.statusCode < 300 && json.ok !== false) {
          if (typeof json.output === 'string' && json.output.length > 0) {
            process.stdout.write(json.output.endsWith('\n') ? json.output : `${json.output}\n`);
          }
          process.exit(0);
        } else {
          const errText =
            typeof json?.error === 'string'
              ? json.error
              : (json?.error?.message || json?.reason || `droid-rpc failed (${res.statusCode})`);
          console.error(errText);
          process.exit(1);
        }
      } catch {
        process.stdout.write(text);
        process.exit(res.statusCode >= 200 && res.statusCode < 300 ? 0 : 1);
      }
    });
  },
);

req.on('timeout', () => {
  req.destroy(new Error('request timed out after 10s'));
});

req.on('error', (err) => {
  console.error(`droid-rpc socket error: ${err.message}`);
  process.exit(1);
});
req.end(body);
