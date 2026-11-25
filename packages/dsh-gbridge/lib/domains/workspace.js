import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { promisify } from 'node:util';
import { GbridgeError, readJsonBody, sendBinary, sendJson } from '../http-util.js';

const execFileAsync = promisify(execFile);

function assertContainedWorkspacePath(baseDir, requestedPath) {
  const realBase = safeRealpath(baseDir);
  if (!realBase) {
    throw new GbridgeError(400, 'gbridge/validation_error', 'workspace base directory could not be resolved');
  }
  const cleanRel = typeof requestedPath === 'string' && requestedPath.trim() ? requestedPath.trim() : '.';
  const candidate = isAbsolute(cleanRel) ? resolve(cleanRel) : resolve(realBase, cleanRel);
  // Check both lexical resolution and symlink-resolved target when it exists.
  const relLex = relative(realBase, candidate);
  if (relLex.startsWith('..') || isAbsolute(relLex)) {
    throw new GbridgeError(403, 'gbridge/path_outside_workspace', 'requested path escapes workspace root');
  }
  const realTarget = safeRealpath(candidate);
  if (realTarget !== realBase && !realTarget.startsWith(realBase + sep)) {
    throw new GbridgeError(403, 'gbridge/path_outside_workspace', 'resolved symlink escapes workspace root');
  }
  return { realBase, fullPath: realTarget };
}

function expandHomePath(p) {
  if (typeof p !== 'string') return '';
  const trimmed = p.trim();
  if (!trimmed) return '';
  if (trimmed === '~') return homedir();
  if (trimmed.startsWith('~/') || trimmed.startsWith('~\\')) {
    return join(homedir(), trimmed.slice(2));
  }
  return trimmed;
}

function safeRealpath(p) {
  const expanded = expandHomePath(p);
  if (!expanded) return '';
  const abs = resolve(expanded);
  try {
    return realpathSync(abs);
  } catch {
    // Walk up until the deepest existing ancestor is realpath'd so non-existent paths beneath
    // a symlink pointing outside the workspace root cannot bypass containment checks.
    const trailing = [];
    let cur = abs;
    while (true) {
      const parent = dirname(cur);
      if (parent === cur) return abs;
      trailing.unshift(basename(cur));
      cur = parent;
      try {
        const realAncestor = realpathSync(cur);
        return join(realAncestor, ...trailing);
      } catch {}
    }
  }
}

function parseIntClamped(raw, fallback, min, max) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.round(n)));
}

function normalizeExplicitWorkspace(w) {
  if (!w || typeof w !== 'object') return null;
  const id = String(w.workspaceId ?? w.id ?? '');
  const path = String(w.path ?? w.rootPath ?? w.cwd ?? '');
  if (!id && !path) return null;
  const sessionIds = Array.isArray(w.sessionIds) ? w.sessionIds.map(String) : [];
  const name = String(w.title ?? w.name ?? (basename(path) || path || id));
  return {
    id: id || path,
    workspaceId: id || undefined,
    name,
    title: name,
    path,
    rootPath: path,
    sessionIds,
    sessionCount: sessionIds.length,
    createdAt: w.createdAt ?? undefined,
    updatedAt: w.updatedAt ?? undefined,
    explicit: true,
    source: 'workspace-registry',
  };
}

/**
 * Authoritative snapshot of explicit DSH Workspaces + archived/pinned session sets.
 * Reads directly from `ctx.workspaceRegistry` when available (instant & exact),
 * falling back to `workspace/follow` baseline frame (`frame.value.items`).
 */
export async function readWorkspaceRegistrySnapshot(ctx, gateway, peer) {
  const reg = ctx?.get?.('workspaceRegistry') ?? ctx?.workspaceRegistry;
  if (reg && typeof reg.list === 'function') {
    const items = reg.list()
      .map((ws) => normalizeExplicitWorkspace({
        workspaceId: String(ws.id),
        path: ws.path,
        title: ws.title,
        sessionIds: Array.isArray(ws.sessionIds) ? [...ws.sessionIds] : [],
        createdAt: ws.createdAt,
        updatedAt: ws.updatedAt,
      }))
      .filter(Boolean);
    return {
      workspaces: items,
      archivedSessionIds: Array.isArray(reg.archivedSessionIds) ? reg.archivedSessionIds.map(String) : [],
      pinnedSessionIds: Array.isArray(reg.pinnedSessionIds) ? reg.pinnedSessionIds.map(String) : [],
    };
  }
  if (gateway?.has('workspace/follow')) {
    const frame = await readFirstStreamFrame(gateway, 'workspace/follow', {}, peer).catch(() => null);
    const val = frame?.value && typeof frame.value === 'object' ? frame.value : frame;
    const rawList = Array.isArray(val?.items)
      ? val.items
      : (Array.isArray(val?.workspaces)
          ? val.workspaces
          : (Array.isArray(frame?.items) ? frame.items : (Array.isArray(frame) ? frame : [])));
    const workspaces = rawList.map(normalizeExplicitWorkspace).filter(Boolean);
    const archivedSessionIds = Array.isArray(val?.archivedSessionIds) ? val.archivedSessionIds.map(String) : [];
    const pinnedSessionIds = Array.isArray(val?.pinnedSessionIds) ? val.pinnedSessionIds.map(String) : [];
    return { workspaces, archivedSessionIds, pinnedSessionIds };
  }
  return { workspaces: [], archivedSessionIds: [], pinnedSessionIds: [] };
}

/**
 * Ensure a real explicit DSH Workspace exists for `dirPath` (reusing existing one by canonical path).
 */
export async function ensureExplicitWorkspaceForPath(ctx, gateway, dirPath, { title, peer } = {}) {
  const clean = typeof dirPath === 'string' ? dirPath.trim() : '';
  if (!clean) return null;
  const canonical = safeRealpath(clean);
  const snap = await readWorkspaceRegistrySnapshot(ctx, gateway, peer);
  const existing = snap.workspaces.find((w) => safeRealpath(w.path) === canonical || w.path === clean);
  if (existing) return existing;

  const reg = ctx?.get?.('workspaceRegistry') ?? ctx?.workspaceRegistry;
  if (reg && typeof reg.create === 'function') {
    try {
      const created = await reg.create(canonical, title ? { title } : undefined);
      return normalizeExplicitWorkspace({
        workspaceId: String(created.id),
        path: created.path,
        title: created.title,
        sessionIds: Array.isArray(created.sessionIds) ? [...created.sessionIds] : [],
      });
    } catch {}
  }

  if (gateway?.has('workspace/create')) {
    try {
      const created = await gateway.call('workspace/create', {
        path: canonical,
        ...(title ? { title } : {}),
      }, { peer });
      return normalizeExplicitWorkspace(created?.workspace ?? created);
    } catch {}
  }
  return null;
}

function fallbackBrowseDir(targetPath, { relativeTo = null, includeDotfiles = false } = {}) {
  const expanded = expandHomePath(targetPath);
  const dir = resolve(expanded || homedir());
  const relRoot = relativeTo ? safeRealpath(relativeTo) : null;
  const dirents = readdirSync(dir, { withFileTypes: true });
  const entries = dirents
    .filter((d) => {
      if (d.name === '.git' || d.name === 'node_modules') return !includeDotfiles ? false : d.name !== '.git';
      return includeDotfiles ? true : !d.name.startsWith('.');
    })
    .map((d) => {
      const absPath = join(dir, d.name);
      const entryPath = relRoot ? relative(relRoot, absPath).replace(/\\/g, '/') : absPath;
      return {
        name: d.name,
        path: entryPath,
        kind: d.isDirectory() ? 'directory' : (d.isSymbolicLink() ? 'symlink' : 'file'),
      };
    })
    .sort((a, b) => (a.kind === 'directory' ? -1 : 1) - (b.kind === 'directory' ? -1 : 1) || a.name.localeCompare(b.name));
  const parent = dirname(dir);
  return { path: dir, parent: parent === dir ? null : parent, home: homedir(), entries, source: 'gbridge-fs-fallback' };
}

async function readFirstStreamFrame(gateway, endpoint, args, peer, timeoutMs = 1500) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const iterable = await gateway.openStream(endpoint, args, { signal: controller.signal, peer });
    for await (const frame of iterable) {
      controller.abort();
      return frame;
    }
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function formatDiffHunksToPatch(file) {
  if (typeof file?.patch === 'string' && file.patch.length > 0) return file.patch;
  if (file?.binary) return 'Binary file changed';
  if (file?.oversized) return 'File exceeds diff preview size limit';
  const hunks = Array.isArray(file?.hunks) ? file.hunks : [];
  if (hunks.length === 0) return '';
  const lines = [];
  for (const h of hunks) {
    const oldStart = Number(h?.oldStart ?? 1);
    const oldLines = Number(h?.oldLines ?? 0);
    const newStart = Number(h?.newStart ?? 1);
    const newLines = Number(h?.newLines ?? 0);
    lines.push(`@@ -${oldStart},${oldLines} +${newStart},${newLines} @@`);
    if (Array.isArray(h?.lines)) {
      for (const l of h.lines) lines.push(String(l));
    }
  }
  return lines.join('\n');
}

function normalizeDiffFile(file) {
  if (!file || typeof file !== 'object') return null;
  const path = String(file.path ?? file.file ?? '');
  if (!path) return null;
  const patch = formatDiffHunksToPatch(file);
  let additions = Number(file.additions ?? file.added ?? 0);
  let deletions = Number(file.deletions ?? file.removed ?? 0);
  if (additions === 0 && deletions === 0 && patch) {
    for (const line of patch.split('\n')) {
      if (line.startsWith('+') && !line.startsWith('+++')) additions += 1;
      else if (line.startsWith('-') && !line.startsWith('---')) deletions += 1;
    }
  }
  return {
    path,
    previousPath: file.previousPath ?? null,
    status: String(file.status ?? 'modified'),
    binary: Boolean(file.binary),
    oversized: Boolean(file.oversized),
    untracked: Boolean(file.untracked),
    additions,
    deletions,
    hunks: Array.isArray(file.hunks) ? file.hunks : [],
    patch,
  };
}

function splitUnifiedGitDiffByFile(rawDiff) {
  const map = new Map();
  if (!rawDiff || typeof rawDiff !== 'string') return map;
  const sections = rawDiff.split(/(?=^diff --git )/m);
  for (const sec of sections) {
    if (!sec.startsWith('diff --git ')) continue;
    const nl = sec.indexOf('\n');
    const header = nl >= 0 ? sec.slice(0, nl) : sec;
    // Parse `diff --git a/<old> b/<new>` or quoted paths
    let fileKey = null;
    const plusMatch = /^\+\+\+\s+(?:b\/)?"?([^\n"]+)"?$/m.exec(sec);
    if (plusMatch && plusMatch[1] && plusMatch[1] !== '/dev/null') {
      fileKey = plusMatch[1].replace(/^b\//, '');
    } else {
      const minusMatch = /^---\s+(?:a\/)?"?([^\n"]+)"?$/m.exec(sec);
      if (minusMatch && minusMatch[1] && minusMatch[1] !== '/dev/null') {
        fileKey = minusMatch[1].replace(/^a\//, '');
      } else {
        const parts = header.slice('diff --git '.length).split(' b/');
        if (parts.length >= 2) fileKey = parts[parts.length - 1].replace(/^"|"$/g, '');
      }
    }
    if (fileKey) {
      const prev = map.get(fileKey);
      map.set(fileKey, prev ? `${prev}\n${sec}` : sec);
    }
  }
  return map;
}

async function runGitAsync(args, execOpts) {
  const { stdout } = await execFileAsync('git', args, execOpts);
  return typeof stdout === 'string' ? stdout : String(stdout ?? '');
}

async function fallbackGitDiff(dirPath, scope = 'uncommitted') {
  const dir = safeRealpath(dirPath);
  if (!dir || !existsSync(dir)) return { base: null, source: 'git-cli', files: [] };
  const execOpts = { cwd: dir, encoding: 'utf8', timeout: 3500, maxBuffer: 8 * 1024 * 1024 };
  try {
    const inside = (await runGitAsync(['rev-parse', '--is-inside-work-tree'], execOpts)).trim();
    if (inside !== 'true') return { base: null, source: 'git-cli', files: [] };
  } catch {
    return { base: null, source: 'git-cli', files: [] };
  }
  let statusOut = '';
  try {
    statusOut = await runGitAsync(['-c', 'core.quotepath=false', 'status', '--porcelain=v1', '-uall'], execOpts);
  } catch {
    return { base: null, source: 'git-cli', files: [] };
  }

  // Run ONE batched async git diff instead of up to 80 blocking execFileSync calls (prevents Node event-loop freeze under PRoot!).
  let combinedDiffOut = '';
  try {
    if (scope === 'staged') {
      combinedDiffOut = await runGitAsync(['-c', 'core.quotepath=false', 'diff', '--cached'], execOpts);
    } else if (scope === 'unstaged') {
      combinedDiffOut = await runGitAsync(['-c', 'core.quotepath=false', 'diff'], execOpts);
    } else {
      try {
        combinedDiffOut = await runGitAsync(['-c', 'core.quotepath=false', 'diff', 'HEAD'], execOpts);
      } catch {
        const [stagedPart, unstagedPart] = await Promise.all([
          runGitAsync(['-c', 'core.quotepath=false', 'diff', '--cached'], execOpts).catch(() => ''),
          runGitAsync(['-c', 'core.quotepath=false', 'diff'], execOpts).catch(() => ''),
        ]);
        combinedDiffOut = [stagedPart, unstagedPart].filter(Boolean).join('\n');
      }
    }
  } catch {}
  const diffByFile = splitUnifiedGitDiffByFile(combinedDiffOut);

  const files = [];
  const rawLines = statusOut.split('\n').filter((l) => l.length >= 4);
  for (const line of rawLines) {
    if (files.length >= 80) break;
    const xy = line.slice(0, 2);
    const x = xy[0];
    const y = xy[1];
    const untracked = xy === '??';
    if (scope === 'staged' && (untracked || x === ' ' || x === '?')) continue;
    if (scope === 'unstaged' && !untracked && y === ' ') continue;
    let filePath = line.slice(3).replace(/\r$/, '');
    let previousPath = null;
    if (filePath.includes(' -> ')) {
      const parts = filePath.split(' -> ');
      previousPath = parts[0].replace(/^"|"$/g, '');
      filePath = parts[parts.length - 1].replace(/^"|"$/g, '');
    } else {
      filePath = filePath.replace(/^"|"$/g, '');
    }
    const statusChar = scope === 'staged' ? x : (scope === 'unstaged' ? y : xy);
    let status = 'modified';
    if (untracked || statusChar.includes('A')) status = 'added';
    else if (statusChar.includes('D')) status = 'deleted';
    else if (statusChar.includes('R')) status = 'renamed';

    let patch = '';
    let binary = false;
    let oversized = false;
    let additions = 0;
    let deletions = 0;
    if (untracked) {
      try {
        const { fullPath } = assertContainedWorkspacePath(dir, filePath);
        const lst = lstatSync(fullPath);
        if (lst.isSymbolicLink()) {
          patch = 'Symlink added';
        } else if (lst.isFile() && lst.size > 64 * 1024) {
          oversized = true;
          patch = 'File exceeds 64 KB preview limit';
        } else if (lst.isFile()) {
          const buf = await readFile(fullPath);
          if (buf.includes(0)) {
            binary = true;
            patch = 'Binary file added';
          } else {
            const textLines = buf.toString('utf8').split('\n');
            additions = textLines.length;
            const preview = textLines.slice(0, 120).map((l) => `+${l}`);
            if (textLines.length > 120) preview.push(`... (+${textLines.length - 120} more lines)`);
            patch = `@@ -0,0 +1,${textLines.length} @@\n${preview.join('\n')}`;
          }
        }
      } catch {}
    } else {
      const diffOut = diffByFile.get(filePath) ?? (previousPath ? diffByFile.get(previousPath) : '') ?? '';
      if (/Binary files .* differ/.test(diffOut)) {
        binary = true;
        patch = 'Binary file changed';
      } else if (diffOut) {
        const patchLines = diffOut.split('\n');
        const hunkStart = patchLines.findIndex((l) => l.startsWith('@@ '));
        const bodyLines = hunkStart >= 0 ? patchLines.slice(hunkStart) : patchLines;
        for (const pl of bodyLines) {
          if (pl.startsWith('+') && !pl.startsWith('+++')) additions += 1;
          else if (pl.startsWith('-') && !pl.startsWith('---')) deletions += 1;
        }
        patch = bodyLines.slice(0, 300).join('\n').trim();
      }
    }
    files.push({
      path: filePath,
      previousPath,
      status,
      binary,
      oversized,
      untracked,
      additions,
      deletions,
      hunks: [],
      patch,
    });
  }
  return { base: null, source: 'git-cli', files };
}

async function listRecentSessionIds(gateway, peer, limit = 8) {
  if (!gateway?.has('session/list')) return [];
  const raw = await gateway.call('session/list', {}, { peer }).catch(() => null);
  const list = Array.isArray(raw)
    ? raw
    : (Array.isArray(raw?.items) ? raw.items : (Array.isArray(raw?.sessions) ? raw.sessions : []));
  return list
    .map((s) => ({
      id: String(s?.sessionId ?? s?.id ?? ''),
      updatedAt: Number(s?.updatedAt ?? s?.createdAt ?? 0),
    }))
    .filter((s) => s.id)
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .slice(0, limit)
    .map((s) => s.id);
}

function resolveDefaultTimeZone(body) {
  const tz = body?.timeZone ?? body?.time_zone ?? body?.timezone;
  if (typeof tz === 'string' && tz.trim()) return tz.trim();
  try {
    const resolved = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (resolved && resolved.includes('/')) return resolved;
  } catch {}
  return 'UTC';
}

function resolveScheduleTiming(body) {
  if (body?.timing && typeof body.timing === 'object' && typeof body.timing.kind === 'string') {
    return body.timing;
  }
  const tz = resolveDefaultTimeZone(body);
  if (body?.everySeconds != null || body?.every_seconds != null) {
    const secs = parseIntClamped(body.everySeconds ?? body.every_seconds, 60, 60, 31536000);
    return { kind: 'every', every_seconds: secs };
  }
  if (body?.afterSeconds != null || body?.after_seconds != null) {
    const secs = parseIntClamped(body.afterSeconds ?? body.after_seconds, 10, 10, 31536000);
    return { kind: 'after', after_seconds: secs };
  }
  if (typeof body?.dailyTime === 'string' && body.dailyTime.trim()) {
    return { kind: 'daily', daily: { time: body.dailyTime.trim(), time_zone: tz } };
  }
  const rawExpr = String(body?.cronExpr ?? body?.cron ?? body?.expression ?? '').trim();
  if (rawExpr) {
    return { kind: 'cron', cron: { expression: rawExpr, time_zone: tz } };
  }
  return undefined;
}

function resolveScheduleTarget(body) {
  if (body?.target && typeof body.target === 'object' && typeof body.target.kind === 'string') {
    return body.target;
  }
  if (typeof body?.sessionId === 'string' && body.sessionId.trim()) {
    return { kind: 'session', sessionId: body.sessionId.trim() };
  }
  const cwd = expandHomePath(String(body?.cwd ?? body?.workspacePath ?? ''));
  const agentPreset = typeof body?.agentPreset === 'string' && body.agentPreset.trim() ? body.agentPreset.trim() : undefined;
  if (cwd || agentPreset) {
    return {
      kind: 'new_once',
      create: {
        ...(cwd ? { cwd } : {}),
        ...(agentPreset ? { agentPreset } : {}),
      },
    };
  }
  return { kind: 'new_once' };
}

export function registerWorkspaceDomain(router, { ctx, gateway, isLocalAndroid = false }) {
  const MAX_TRACKED_ENTRIES = 512;
  const terminalSessionMap = new Map();
  const jobSessionMap = new Map();
  const trackBounded = (map, key, val) => {
    if (!key) return;
    if (map.has(key)) map.delete(key);
    map.set(key, val);
    while (map.size > MAX_TRACKED_ENTRIES) {
      const oldest = map.keys().next().value;
      if (oldest === undefined) break;
      map.delete(oldest);
    }
  };

  // ---------------- Workspaces & Files ----------------
  router.get('/workspaces', async (_req, res, { peer }) => {
    const snap = await readWorkspaceRegistrySnapshot(ctx, gateway, peer);
    const explicit = snap.workspaces;

    const seenPaths = new Set(
      explicit
        .map((w) => safeRealpath(w.rootPath ?? w.path))
        .filter(Boolean),
    );

    const derived = [];
    if (gateway.has('session/list')) {
      const rawSessions = await gateway.call('session/list', {}, { peer }).catch(() => null);
      const sessions = Array.isArray(rawSessions)
        ? rawSessions
        : (Array.isArray(rawSessions?.items)
            ? rawSessions.items
            : (Array.isArray(rawSessions?.sessions) ? rawSessions.sessions : []));
      const byCwd = new Map();
      for (const s of sessions) {
        const cwd = s?.cwd ?? s?.projections?.values?.workingDirectory;
        if (typeof cwd !== 'string' || !cwd.trim()) continue;
        const canon = safeRealpath(cwd);
        if (seenPaths.has(canon)) continue;
        const ts = Number(s?.updatedAt ?? 0);
        const sid = s?.sessionId ?? s?.id ?? null;
        const cur = byCwd.get(canon);
        if (!cur) {
          byCwd.set(canon, {
            id: cwd,
            name: basename(cwd) || cwd,
            title: basename(cwd) || cwd,
            path: cwd,
            rootPath: cwd,
            sessionIds: sid ? [sid] : [],
            sessionCount: 1,
            latestSessionId: sid,
            lastUsedAt: ts,
            explicit: false,
            source: 'sessions',
          });
        } else {
          cur.sessionCount += 1;
          if (sid) cur.sessionIds.push(sid);
          if (ts > cur.lastUsedAt) {
            cur.lastUsedAt = ts;
            if (sid) cur.latestSessionId = sid;
          }
        }
      }
      derived.push(...[...byCwd.values()].sort((a, b) => b.lastUsedAt - a.lastUsedAt));
    }

    const workspaces = [...explicit, ...derived];
    if (workspaces.length === 0) {
      const envDefault = process.env.GBRIDGE_DEFAULT_WORKSPACE?.trim();
      const home = homedir();
      const androidWs = join(home, 'workspace');
      const defaultPath = envDefault || (existsSync(androidWs) ? androidWs : home);
      workspaces.push({
        id: defaultPath,
        name: basename(defaultPath) || 'workspace',
        title: basename(defaultPath) || 'workspace',
        path: defaultPath,
        rootPath: defaultPath,
        sessionIds: [],
        sessionCount: 0,
        explicit: false,
        source: 'default-home',
      });
    }
    sendJson(res, 200, {
      v: 1,
      workspaces,
      archivedSessionIds: snap.archivedSessionIds,
      pinnedSessionIds: snap.pinnedSessionIds,
    });
  }, { domain: 'files' });

  router.post('/workspaces', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const reqPath = expandHomePath(typeof body.path === 'string' ? body.path : '');
    const reqTitle = typeof body.title === 'string' && body.title.trim()
      ? body.title.trim()
      : (typeof body.name === 'string' && body.name.trim() ? body.name.trim() : undefined);
    const created = await gateway.call('workspace/create', {
      ...body,
      ...(reqPath ? { path: reqPath } : {}),
      ...(reqTitle ? { title: reqTitle } : {}),
    }, { peer });
    let norm = normalizeExplicitWorkspace(created?.workspace ?? created);
    // DSH workspace/create ignores custom `title`; immediately rename when a custom title was requested.
    if (norm?.workspaceId && reqTitle && norm.title !== reqTitle && gateway.has('workspace/rename')) {
      try {
        await gateway.call('workspace/rename', { workspaceId: norm.workspaceId, title: reqTitle }, { peer });
        norm = { ...norm, title: reqTitle, name: reqTitle };
      } catch {}
    }

    // Optionally attach matching ungrouped sessions so they immediately appear grouped in Official WebUI!
    let attachedCount = 0;
    const reg = ctx?.get?.('workspaceRegistry') ?? ctx?.workspaceRegistry;
    if (norm?.workspaceId && body.attachMatchingSessions !== false && reg && typeof reg.get === 'function' && gateway.has('session/list')) {
      const entity = reg.get(norm.workspaceId);
      if (entity && typeof entity.attachSession === 'function') {
        const rawSessions = await gateway.call('session/list', {}, { peer }).catch(() => null);
        const sessions = Array.isArray(rawSessions) ? rawSessions : (rawSessions?.items ?? rawSessions?.sessions ?? []);
        const targetPath = safeRealpath(norm.path);
        for (const s of sessions) {
          const sid = s?.sessionId ?? s?.id;
          const scwd = s?.cwd ?? s?.projections?.values?.workingDirectory;
          if (!sid || !scwd) continue;
          if (safeRealpath(scwd) === targetPath) {
            try {
              await entity.attachSession(String(sid));
              attachedCount += 1;
            } catch {}
          }
        }
      }
    }
    sendJson(res, 201, { v: 1, workspace: norm ?? created, attachedCount });
  }, { domain: 'files' });

  router.post('/workspaces/organize-by-cwd', async (_req, res, { peer }) => {
    const rawSessions = gateway.has('session/list')
      ? await gateway.call('session/list', {}, { peer }).catch(() => [])
      : [];
    const sessions = Array.isArray(rawSessions) ? rawSessions : (rawSessions?.items ?? rawSessions?.sessions ?? []);
    const reg = ctx?.get?.('workspaceRegistry') ?? ctx?.workspaceRegistry;
    const createdWorkspaces = [];
    let attachedCount = 0;

    const byDir = new Map();
    for (const s of sessions) {
      const sid = s?.sessionId ?? s?.id;
      const scwd = s?.cwd ?? s?.projections?.values?.workingDirectory;
      if (!sid || typeof scwd !== 'string' || !scwd.trim()) continue;
      const canon = safeRealpath(scwd);
      if (!byDir.has(canon)) byDir.set(canon, { path: scwd, sids: [] });
      byDir.get(canon).sids.push(String(sid));
    }

    for (const [canon, info] of byDir.entries()) {
      const ws = await ensureExplicitWorkspaceForPath(ctx, gateway, canon, { peer });
      if (!ws?.workspaceId) continue;
      createdWorkspaces.push(ws);
      const entity = reg?.get?.(ws.workspaceId);
      if (entity && typeof entity.attachSession === 'function') {
        for (const sid of info.sids) {
          try {
            await entity.attachSession(sid);
            attachedCount += 1;
          } catch {}
        }
      }
    }
    sendJson(res, 200, {
      v: 1,
      workspacesCount: createdWorkspaces.length,
      attachedCount,
    });
  }, { domain: 'files' });

  router.post('/workspaces/:id/attach-session', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const sessionId = String(body.sessionId || '');
    if (!sessionId) throw new GbridgeError(400, 'gbridge/validation_error', 'sessionId is required');
    const reg = ctx?.get?.('workspaceRegistry') ?? ctx?.workspaceRegistry;
    const entity = reg?.get?.(params.id);
    if (entity && typeof entity.attachSession === 'function') {
      await entity.attachSession(sessionId);
      sendJson(res, 200, { v: 1, workspaceId: params.id, sessionId, attached: true });
      return;
    }
    throw new GbridgeError(404, 'workspace/not_found', `workspace "${params.id}" not found`);
  }, { domain: 'files' });

  router.patch('/workspaces/:id', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const results = {};
    const nextTitle = typeof body.title === 'string' ? body.title : (typeof body.name === 'string' ? body.name : null);
    if (nextTitle !== null) {
      results.rename = await gateway.call('workspace/rename', {
        workspaceId: params.id,
        title: nextTitle,
      }, { peer });
    }
    const beforeWs = body.beforeWorkspaceId !== undefined ? body.beforeWorkspaceId : body.beforeId;
    if (typeof beforeWs === 'string' || beforeWs === null) {
      results.reorder = await gateway.call('workspace/insertBefore', {
        workspaceId: params.id,
        ...(beforeWs ? { beforeWorkspaceId: beforeWs } : {}),
      }, { peer });
    }
    sendJson(res, 200, { v: 1, results });
  }, { domain: 'files' });

  router.delete('/workspaces/:id', async (_req, res, { params, peer }) => {
    const result = await gateway.call('workspace/delete', { workspaceId: params.id }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'files' });

  async function assertAllowedBrowsePath(targetPath, peer) {
    const realTarget = safeRealpath(targetPath || homedir());
    if (!realTarget) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'directory path could not be resolved');
    }
    const allowedRoots = [];
    const homeReal = safeRealpath(homedir());
    if (homeReal) allowedRoots.push(homeReal);
    if (isLocalAndroid) {
      for (const androidRoot of ['/sdcard', '/storage/emulated/0']) {
        if (existsSync(androidRoot)) {
          const r = safeRealpath(androidRoot);
          if (r) allowedRoots.push(r);
        }
      }
    }
    const snap = await readWorkspaceRegistrySnapshot(ctx, gateway, peer).catch(() => ({ workspaces: [] }));
    for (const w of snap.workspaces) {
      const wReal = safeRealpath(w.path);
      if (wReal) allowedRoots.push(wReal);
    }
    const isAllowed = allowedRoots.some((root) => realTarget === root || realTarget.startsWith(root + sep));
    if (!isAllowed) {
      throw new GbridgeError(403, 'gbridge/path_outside_workspace', 'requested directory is outside allowed roots');
    }
    return realTarget;
  }

  router.get('/fs/browse', async (_req, res, { searchParams, peer }) => {
    const rawPath = searchParams.get('path') || undefined;
    const expandedPath = rawPath ? expandHomePath(rawPath) : homedir();
    const safePath = await assertAllowedBrowsePath(expandedPath, peer);
    if (gateway.has('directoryPicker/list')) {
      try {
        const resData = await gateway.call('directoryPicker/list', { path: safePath }, { peer });
        if (Array.isArray(resData)) {
          const curDir = safePath;
          const parent = dirname(curDir);
          sendJson(res, 200, {
            v: 1,
            path: curDir,
            parent: parent === curDir ? null : parent,
            home: homedir(),
            entries: resData,
          });
          return;
        }
        if (resData && typeof resData === 'object') {
          const curDir = String(resData.path || safePath);
          const parent = resData.parent !== undefined ? resData.parent : (dirname(curDir) === curDir ? null : dirname(curDir));
          const list = Array.isArray(resData.entries)
            ? resData.entries
            : (Array.isArray(resData.items) ? resData.items : []);
          sendJson(res, 200, {
            v: 1,
            path: curDir,
            parent,
            home: homedir(),
            entries: list,
          });
          return;
        }
      } catch (err) {
        if (err?.details?.upstreamCode !== 'directory-picker/unavailable') {
          // Fall back gracefully to direct filesystem browse when upstream fails
        }
      }
    }
    sendJson(res, 200, { v: 1, ...fallbackBrowseDir(safePath) });
  }, { domain: 'files' });

  router.post('/fs/mkdir', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const basePath = expandHomePath(String(body.path || homedir()));
    const safeBasePath = await assertAllowedBrowsePath(basePath, peer);
    const childName = typeof body.name === 'string' ? body.name.trim() : '';
    if (childName && (childName.includes('/') || childName.includes('\\') || childName === '..' || childName === '.')) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'directory name cannot contain path separators or traversal segments');
    }
    const fullTarget = childName
      ? assertContainedWorkspacePath(safeBasePath, childName).fullPath
      : safeBasePath;
    if (gateway.has('directoryPicker/createDirectory')) {
      try {
        const result = await gateway.call('directoryPicker/createDirectory', {
          ...body,
          path: safeBasePath,
          ...(childName ? { name: childName } : {}),
        }, { peer });
        sendJson(res, 201, { v: 1, path: fullTarget, result });
        return;
      } catch {}
    }
    mkdirSync(fullTarget, { recursive: true });
    sendJson(res, 201, { v: 1, path: fullTarget, created: true });
  }, { domain: 'files' });

  async function resolveWorkspaceScope(idParam, querySessionId, peer) {
    let sid = querySessionId || null;
    const requestedPath = idParam.startsWith('/') || idParam.startsWith('~') ? expandHomePath(idParam) : null;
    const requestedReal = requestedPath ? safeRealpath(requestedPath) : null;
    let dirPath = null;
    const snap = await readWorkspaceRegistrySnapshot(ctx, gateway, peer).catch(() => ({ workspaces: [] }));
    // Prioritize explicit workspace ID or explicit filesystem path over ambient querySessionId
    // so browsing Workspace B while Session A is active never resolves back to Workspace A!
    const matched =
      snap.workspaces.find((w) => w.id === idParam || w.workspaceId === idParam) ||
      (requestedReal ? snap.workspaces.find((w) => safeRealpath(w.path) === requestedReal) : null) ||
      (sid ? snap.workspaces.find((w) => Array.isArray(w.sessionIds) && w.sessionIds.includes(sid)) : null) ||
      snap.workspaces.find((w) => Array.isArray(w.sessionIds) && w.sessionIds.includes(idParam));
    if (matched) {
      if (matched.path) dirPath = matched.path;
      const wsSessions = Array.isArray(matched.sessionIds) ? matched.sessionIds : [];
      if (sid && !wsSessions.includes(sid)) {
        // querySessionId belongs to a different workspace — bind to a session inside `matched` instead.
        sid = wsSessions.length > 0 ? wsSessions[wsSessions.length - 1] : null;
      } else if (!sid && wsSessions.length > 0) {
        sid = wsSessions.includes(idParam) ? idParam : wsSessions[wsSessions.length - 1];
      }
    } else if (requestedReal) {
      // Security confinement: only permit explicit path-based scope if inside a registered workspace or user's $HOME (never `/` root!).
      const homeReal = safeRealpath(homedir());
      const insideRegistered = snap.workspaces.some((w) => {
        const wReal = safeRealpath(w.path);
        return wReal && (requestedReal === wReal || requestedReal.startsWith(wReal + sep));
      });
      const insideHome = homeReal && (requestedReal === homeReal || requestedReal.startsWith(homeReal + sep));
      if (insideRegistered || insideHome) {
        dirPath = requestedReal;
      }
    }
    return { sid, dirPath };
  }

  router.get('/workspaces/:id/files/tree', async (_req, res, { params, searchParams, peer }) => {
    const relPath = searchParams.get('path') || '.';
    const { sid, dirPath } = await resolveWorkspaceScope(params.id, searchParams.get('sessionId'), peer);
    const scopeId = sid || (!params.id.startsWith('/') ? params.id : null);
    if (scopeId && gateway.has('workspaceFiles/list')) {
      try {
        const entries = await gateway.call('workspaceFiles/list', {
          workspaceFileScopeId: scopeId,
          workspaceId: params.id,
          path: relPath,
        }, { peer });
        sendJson(res, 200, { v: 1, entries });
        return;
      } catch (err) {
        if (!dirPath) throw err;
      }
    }
    if (!dirPath) {
      throw new GbridgeError(403, 'gbridge/workspace_not_allowed', 'requested workspace path is outside allowed roots');
    }
    const { realBase, fullPath: targetDir } = assertContainedWorkspacePath(dirPath, relPath);
    sendJson(res, 200, {
      v: 1,
      entries: fallbackBrowseDir(targetDir, { relativeTo: realBase, includeDotfiles: true }),
    });
  }, { domain: 'files' });

  router.get('/workspaces/:id/files/read', async (_req, res, { params, searchParams, peer }) => {
    const path = searchParams.get('path');
    if (!path) throw new GbridgeError(400, 'gbridge/validation_error', 'query param path is required');
    const binary = searchParams.get('binary') === 'true';
    const offset = parseIntClamped(searchParams.get('offset') ?? 1, 1, 1, 1000000);
    const limit = parseIntClamped(searchParams.get('limit') ?? 400, 400, 1, 5000);
    const { sid, dirPath } = await resolveWorkspaceScope(params.id, searchParams.get('sessionId'), peer);
    const scopeId = sid || (!params.id.startsWith('/') ? params.id : null);
    const ep = binary && gateway.has('workspaceFiles/readBytes') ? 'workspaceFiles/readBytes' : 'workspaceFiles/read';
    if (scopeId && gateway.has(ep)) {
      try {
        const data = await gateway.call(ep, {
          workspaceFileScopeId: scopeId,
          workspaceId: params.id,
          path,
          range: { offset, limit },
          options: {},
        }, { peer });
        const rawBytes = (Buffer.isBuffer(data) || data instanceof Uint8Array)
          ? data
          : ((Buffer.isBuffer(data?.data) || data?.data instanceof Uint8Array) ? data.data : null);
        if (binary && rawBytes) {
          sendBinary(res, 200, rawBytes, data?.mimeType || 'application/octet-stream');
          return;
        }
        sendJson(res, 200, { v: 1, file: data });
        return;
      } catch (err) {
        if (!dirPath) throw err;
      }
    }
    if (!dirPath) {
      throw new GbridgeError(403, 'gbridge/workspace_not_allowed', 'requested workspace path is outside allowed roots');
    }
    const { realBase, fullPath } = assertContainedWorkspacePath(dirPath, path);
    let st;
    try {
      st = await stat(fullPath);
    } catch (err) {
      if (err?.code === 'ENOENT') {
        throw new GbridgeError(404, 'gbridge/file_not_found', 'requested file does not exist');
      }
      if (err?.code === 'EACCES' || err?.code === 'EPERM') {
        throw new GbridgeError(403, 'gbridge/file_access_denied', 'permission denied reading file');
      }
      throw err;
    }
    if (!st.isFile()) {
      throw new GbridgeError(400, 'gbridge/not_a_regular_file', 'requested path is not a regular file');
    }
    if (binary) {
      if (st.size > 4 * 1024 * 1024) {
        throw new GbridgeError(413, 'gbridge/file_too_large', 'binary file exceeds 4MB preview cap');
      }
      sendBinary(res, 200, await readFile(fullPath));
      return;
    }
    if (st.size > 1024 * 1024) {
      throw new GbridgeError(413, 'gbridge/file_too_large', 'file exceeds 1MB preview cap');
    }
    const rawBuf = await readFile(fullPath);
    const sample = rawBuf.subarray(0, Math.min(rawBuf.length, 8192));
    if (sample.includes(0)) {
      sendJson(res, 200, {
        v: 1,
        file: {
          path: relative(realBase, fullPath).replace(/\\/g, '/'),
          binary: true,
          bytes: st.size,
          text: '',
          lines: 0,
          totalLines: 0,
          offset,
          limit,
          eof: true,
        },
      });
      return;
    }
    const allLines = rawBuf.toString('utf8').split('\n');
    const slice = allLines.slice(offset - 1, offset - 1 + limit);
    const eof = (offset - 1 + limit) >= allLines.length;
    sendJson(res, 200, {
      v: 1,
      file: {
        path: relative(realBase, fullPath).replace(/\\/g, '/'),
        text: slice.join('\n'),
        lines: slice.length,
        totalLines: allLines.length,
        offset,
        limit,
        eof,
      },
    });
  }, { domain: 'files' });

  router.get('/workspaces/:id/files/changes', async (_req, res, { params, searchParams, peer }) => {
    const requestedScope = searchParams.get('scope');
    const validScope = ['uncommitted', 'unstaged', 'staged'].includes(requestedScope) ? requestedScope : 'uncommitted';
    const resolved = await resolveWorkspaceScope(params.id, searchParams.get('sessionId'), peer);
    const sid = resolved.sid;
    const dirPath = resolved.dirPath;

    if (sid && gateway.has('forgePanel/localDiff')) {
      try {
        const diff = await gateway.call('forgePanel/localDiff', {
          sessionId: sid,
          scope: { kind: validScope },
        }, { peer });
        if (diff && typeof diff === 'object' && Array.isArray(diff.files)) {
          const files = diff.files.map(normalizeDiffFile).filter(Boolean);
          sendJson(res, 200, { v: 1, changes: { ...diff, source: 'forge-local-diff', files } });
          return;
        }
      } catch {}
    }

    if (dirPath && existsSync(dirPath)) {
      const gitDiff = await fallbackGitDiff(dirPath, validScope);
      sendJson(res, 200, { v: 1, changes: gitDiff });
      return;
    }

    if (sid && gateway.has('workspaceFiles/changes')) {
      const frame = await readFirstStreamFrame(gateway, 'workspaceFiles/changes', {
        workspaceFileScopeId: sid,
        workspaceId: params.id,
        path: '',
      }, peer).catch(() => null);
      sendJson(res, 200, { v: 1, changes: frame ?? { base: null, files: [] } });
      return;
    }
    sendJson(res, 200, { v: 1, changes: { base: null, files: [] } });
  }, { domain: 'files' });

  router.post('/workspaces/:id/files/office-preview', async (req, res, { params, searchParams, peer }) => {
    const body = await readJsonBody(req);
    const { sid } = await resolveWorkspaceScope(params.id, body.sessionId || searchParams.get('sessionId'), peer);
    const ep = gateway.has('officeKit/render') ? 'officeKit/render' : 'officeToPdf/render';
    const rawPriority = body.priority;
    const priority = rawPriority === 'background' ? 'background' : 'foreground';
    const result = await gateway.call(ep, {
      workspaceFileScopeId: sid || params.id,
      workspaceId: params.id,
      ...body,
      priority,
    }, { peer });
    const pdfBytes = (Buffer.isBuffer(result) || result instanceof Uint8Array)
      ? result
      : ((Buffer.isBuffer(result?.data) || result?.data instanceof Uint8Array) ? result.data : null);
    if (pdfBytes) {
      sendBinary(res, 200, pdfBytes, 'application/pdf');
      return;
    }
    sendJson(res, 200, { v: 1, preview: result });
  }, { domain: 'files' });

  // ---------------- Terminal ----------------
  router.get('/terminals', async (_req, res, { searchParams, peer }) => {
    const explicitSid = searchParams.get('sessionId') || searchParams.get('agentId');
    if (explicitSid) {
      const list = await gateway.call('terminal/list', { sessionId: explicitSid }, { peer }).catch(() => []);
      const terminals = (Array.isArray(list) ? list : []).map((t) => {
        if (t?.id) trackBounded(terminalSessionMap, String(t.id), explicitSid);
        return { ...t, sessionId: explicitSid };
      });
      sendJson(res, 200, { v: 1, terminals });
      return;
    }
    const recentSids = await listRecentSessionIds(gateway, peer, 6);
    const settled = await Promise.allSettled(
      recentSids.map(async (sid) => {
        const list = await gateway.call('terminal/list', { sessionId: sid }, { peer });
        return (Array.isArray(list) ? list : []).map((t) => {
          if (t?.id) trackBounded(terminalSessionMap, String(t.id), sid);
          return { ...t, sessionId: sid };
        });
      }),
    );
    const merged = [];
    const seen = new Set();
    for (const r of settled) {
      if (r.status !== 'fulfilled') continue;
      for (const item of r.value) {
        const key = String(item?.id ?? '');
        if (!key || seen.has(key)) continue;
        seen.add(key);
        merged.push(item);
      }
    }
    sendJson(res, 200, { v: 1, terminals: merged });
  }, { domain: 'terminal' });

  router.get('/terminals/shells', async (_req, res, { searchParams, peer }) => {
    let agentId = searchParams.get('agentId') || searchParams.get('sessionId') || undefined;
    if (!agentId) {
      const recent = await listRecentSessionIds(gateway, peer, 1);
      agentId = recent[0];
    }
    if (agentId) {
      try {
        const shells = await gateway.call('terminal/shells', { agentId }, { peer });
        sendJson(res, 200, { v: 1, shells });
        return;
      } catch {}
    }
    const candidates = [process.env.SHELL, '/bin/zsh', '/bin/bash', '/bin/sh'].filter(Boolean);
    const unique = [...new Set(candidates)].filter((p) => existsSync(p));
    const fallbackShells = unique.map((p, idx) => ({
      path: p,
      name: basename(p),
      isDefault: idx === 0,
    }));
    sendJson(res, 200, { v: 1, shells: fallbackShells });
  }, { domain: 'terminal' });

  router.post('/terminals', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    let agentId = body.agentId ?? body.sessionId;
    if (!agentId) {
      const recent = await listRecentSessionIds(gateway, peer, 1);
      agentId = recent[0];
    }
    if (!agentId) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'sessionId is required to create a terminal when no session exists');
    }
    const termReq = {
      id: body.id || randomUUID(),
      cols: parseIntClamped(body.cols ?? 80, 80, 10, 500),
      rows: parseIntClamped(body.rows ?? 24, 24, 4, 200),
      ...(body.shellPath || body.shell ? { shellPath: body.shellPath ?? body.shell } : {}),
    };
    const terminal = await gateway.call('terminal/create', {
      agentId,
      request: body.request ?? termReq,
    }, { peer });
    const termId = String(terminal?.id ?? termReq.id);
    trackBounded(terminalSessionMap, termId, String(agentId));
    sendJson(res, 201, {
      v: 1,
      terminal: {
        ...(terminal && typeof terminal === 'object' ? terminal : { id: termId }),
        sessionId: String(agentId),
      },
    });
  }, { domain: 'terminal' });

  router.patch('/terminals/:id', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const agentId = body.agentId ?? body.sessionId ?? terminalSessionMap.get(params.id);
    const results = {};
    if (typeof body.title === 'string') {
      results.rename = await gateway.call('terminal/rename', {
        ...(agentId ? { agentId } : {}),
        id: params.id,
        title: body.title,
      }, { peer });
    }
    if (typeof body.cols === 'number' && typeof body.rows === 'number' && gateway.has('terminal/resize')) {
      results.resize = await gateway.call('terminal/resize', {
        id: params.id,
        terminalId: params.id,
        cols: body.cols,
        rows: body.rows,
      }, { peer });
    }
    // Note: in DSH 0.2.2-rc.5 `terminal/retain` is a stream endpoint (`mode: 'stream'`) managed via
    // WS terminal channel subscriptions; never invoke it as unary RPC.
    sendJson(res, 200, { v: 1, results });
  }, { domain: 'terminal' });

  router.delete('/terminals/:id', async (_req, res, { params, searchParams, peer }) => {
    let agentId = searchParams.get('agentId') || searchParams.get('sessionId') || terminalSessionMap.get(params.id);
    if (!agentId) {
      const recent = await listRecentSessionIds(gateway, peer, 1);
      agentId = recent[0];
    }
    const result = await gateway.call('terminal/close', {
      ...(agentId ? { agentId } : {}),
      id: params.id,
    }, { peer });
    terminalSessionMap.delete(params.id);
    sendJson(res, 200, { v: 1, closed: true, result });
  }, { domain: 'terminal' });

  // ---------------- Subagents, Teams, Trajectory & Jobs ----------------
  router.get('/sessions/:id/projections', async (_req, res, { params, peer }) => {
    const projections = await gateway.call('session/projections', { sessionId: params.id }, { peer });
    sendJson(res, 200, { v: 1, sessionId: params.id, projections });
  }, { domain: 'subagents' });

  router.post('/subagents/:id/prompt', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const requestObj = body.request && typeof body.request === 'object'
      ? { childSessionId: params.id, ...body.request }
      : {
          requestId: body.requestId || randomUUID(),
          childSessionId: params.id,
          ...(body.parentSessionId ? { parentSessionId: String(body.parentSessionId) } : {}),
          mode: body.mode || 'continuable',
          delivery: body.delivery === 'queue' ? 'queue' : 'steer',
          content: Array.isArray(body.content)
            ? body.content
            : [{ type: 'text', text: String(body.text ?? '') }],
          ...(body.clientTimeZone ? { clientTimeZone: body.clientTimeZone } : {}),
        };
    const result = await gateway.call('subagents/prompt', { request: requestObj }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'subagents' });

  router.post('/subagents/:id/interrupt', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const ep = gateway.has('subagents/interruptByUser')
      ? 'subagents/interruptByUser'
      : 'subagents/interruptByParent';
    const result = await gateway.call(ep, {
      childSessionId: params.id,
      subagentId: params.id,
      ...(body.parentSessionId ? { parentSessionId: String(body.parentSessionId) } : {}),
      mode: body.mode || 'continuable',
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'subagents' });

  router.get('/jobs', async (_req, res, { searchParams, peer }) => {
    const explicitSid = searchParams.get('sessionId') || undefined;
    if (!gateway.has('job/list')) {
      sendJson(res, 200, { v: 1, jobs: [] });
      return;
    }
    const sids = explicitSid ? [explicitSid] : await listRecentSessionIds(gateway, peer, 8);
    const settled = await Promise.allSettled(
      sids.map(async (sid) => {
        const frame = await readFirstStreamFrame(gateway, 'job/list', { request: { sessionId: sid } }, peer, 1200);
        const list = Array.isArray(frame?.jobs)
          ? frame.jobs
          : (Array.isArray(frame?.items) ? frame.items : (Array.isArray(frame) ? frame : []));
        return list.map((j) => {
          const jid = String(j?.id ?? j?.jobId ?? '');
          if (jid) trackBounded(jobSessionMap, jid, sid);
          return { ...(j && typeof j === 'object' ? j : {}), sessionId: j?.sessionId ?? sid };
        });
      }),
    );
    const jobs = [];
    const seen = new Set();
    for (const r of settled) {
      if (r.status !== 'fulfilled') continue;
      for (const j of r.value) {
        const key = String(j?.id ?? j?.jobId ?? '');
        if (key && seen.has(key)) continue;
        if (key) seen.add(key);
        jobs.push(j);
      }
    }
    sendJson(res, 200, { v: 1, jobs });
  }, { domain: 'jobs' });

  router.post('/jobs/:id/kill', async (req, res, { params, searchParams, peer }) => {
    const body = await readJsonBody(req).catch(() => ({}));
    let sessionId = body?.sessionId || searchParams.get('sessionId') || jobSessionMap.get(params.id);
    if (!sessionId) {
      const recent = await listRecentSessionIds(gateway, peer, 1);
      sessionId = recent[0];
    }
    const result = await gateway.call('job/kill', {
      request: {
        ...(sessionId ? { sessionId } : {}),
        jobId: params.id,
      },
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'jobs' });

  // ---------------- Schedule (Automation) ----------------
  router.get('/schedules', async (_req, res, { peer }) => {
    const ep = gateway.has('schedule/catalog') ? 'schedule/catalog' : 'schedule/list';
    const raw = await gateway.call(ep, {}, { peer });
    const schedules = Array.isArray(raw)
      ? raw
      : (Array.isArray(raw?.items) ? raw.items : (Array.isArray(raw?.schedules) ? raw.schedules : []));
    sendJson(res, 200, { v: 1, schedules });
  }, { domain: 'schedule' });

  router.post('/schedules', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    let requestObj;
    if (body?.request && typeof body.request === 'object') {
      requestObj = body.request;
    } else {
      const title = String(body.title ?? body.name ?? '').trim();
      const prompt = String(body.prompt ?? body.command ?? '').trim();
      const timing = resolveScheduleTiming(body);
      if (!title) throw new GbridgeError(400, 'gbridge/validation_error', 'schedule title is required');
      if (!prompt) throw new GbridgeError(400, 'gbridge/validation_error', 'schedule prompt is required');
      if (!timing) throw new GbridgeError(400, 'gbridge/validation_error', 'schedule timing or cronExpr is required');
      requestObj = {
        title: title.slice(0, 120),
        prompt,
        timing,
        target: resolveScheduleTarget(body),
      };
    }
    const created = await gateway.call('schedule/create', { request: requestObj }, { peer });
    sendJson(res, 201, { v: 1, schedule: created });
  }, { domain: 'schedule' });

  router.get('/schedules/:id/history', async (_req, res, { params, searchParams, peer }) => {
    const limit = parseIntClamped(searchParams.get('limit') ?? 20, 20, 1, 100);
    const before = searchParams.get('before') || undefined;
    const history = await gateway.call('schedule/history', {
      request: {
        id: params.id,
        limit,
        ...(before ? { before } : {}),
      },
    }, { peer });
    sendJson(res, 200, { v: 1, history });
  }, { domain: 'schedule' });

  router.patch('/schedules/:id', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const ep = gateway.has('schedule/edit') ? 'schedule/edit' : 'schedule/update';
    if (ep === 'schedule/edit') {
      let requestObj;
      if (body?.request && typeof body.request === 'object') {
        requestObj = { id: params.id, ...body.request };
      } else if (body?.action === 'delete') {
        requestObj = {
          id: params.id,
          action: 'delete',
          ...(body.expectedUpdatedAt ? { expectedUpdatedAt: body.expectedUpdatedAt } : {}),
        };
      } else {
        const patch = body?.patch && typeof body.patch === 'object' ? { ...body.patch } : {};
        if (typeof body.title === 'string' && body.title.trim()) patch.title = body.title.trim();
        else if (typeof body.name === 'string' && body.name.trim()) patch.title = body.name.trim();
        if (typeof body.prompt === 'string' && body.prompt.trim()) patch.prompt = body.prompt.trim();
        const timing = resolveScheduleTiming(body);
        if (timing) patch.timing = timing;
        if (body.target && typeof body.target === 'object') patch.target = body.target;
        if (typeof body.active === 'boolean') patch.active = body.active;
        else if (typeof body.enabled === 'boolean') patch.active = body.enabled;
        requestObj = {
          id: params.id,
          action: 'update',
          patch,
          ...(body.expectedUpdatedAt ? { expectedUpdatedAt: body.expectedUpdatedAt } : {}),
        };
      }
      const result = await gateway.call('schedule/edit', { request: requestObj }, { peer });
      sendJson(res, 200, { v: 1, result });
      return;
    }
    const result = await gateway.call(ep, { scheduleId: params.id, id: params.id, ...body }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'schedule' });

  router.delete('/schedules/:id', async (_req, res, { params, peer }) => {
    if (gateway.has('schedule/delete')) {
      const result = await gateway.call('schedule/delete', { scheduleId: params.id, id: params.id }, { peer });
      sendJson(res, 200, { v: 1, deleted: true, result });
      return;
    }
    const result = await gateway.call('schedule/edit', {
      request: { id: params.id, action: 'delete' },
    }, { peer });
    sendJson(res, 200, { v: 1, deleted: true, result });
  }, { domain: 'schedule' });

  router.post('/schedules/prune', async (_req, res, { peer }) => {
    const result = await gateway.call('schedule/deleteInactive', {}, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'schedule' });

  router.post('/schedules/:id/run', async (_req, res, { params, peer }) => {
    const result = await gateway.call('schedule/run', { request: { id: params.id } }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'schedule' });
}
