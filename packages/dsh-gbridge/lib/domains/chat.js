import { randomUUID } from 'node:crypto';
import {
  DEFAULT_MAX_UPLOAD_BYTES,
  GbridgeError,
  readJsonBody,
  readRawBody,
  sendBinary,
  sendJson,
} from '../http-util.js';
import { ensureExplicitWorkspaceForPath, readWorkspaceRegistrySnapshot } from './workspace.js';

function usesAddressEnvelope(gateway, endpoint) {
  try {
    const desc = gateway.typert?.local?.get?.(endpoint);
    const schema = desc?.parameters?.[0]?.codec?.jsonSchema;
    return Boolean(schema?.properties?.address);
  } catch {
    return false;
  }
}

function usesContentPromptEnvelope(gateway) {
  try {
    const desc = gateway.typert?.local?.get?.('session/prompt');
    const schema = desc?.parameters?.[0]?.codec?.jsonSchema;
    return Boolean(schema?.properties?.requestId && schema?.properties?.content);
  } catch {
    return false;
  }
}

function basenameFromCwd(cwd) {
  if (typeof cwd !== 'string') return null;
  const trimmed = cwd.trim().replace(/\/+$/, '');
  if (!trimmed || trimmed === '/') return null;
  const parts = trimmed.split('/').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : null;
}

function sanitizeSessionTitle(rawTitle, cwd) {
  let str = '';
  let hadCorruptObject = false;
  if (typeof rawTitle === 'string') {
    str = rawTitle;
  } else if (Array.isArray(rawTitle)) {
    str = rawTitle
      .map((part) => (typeof part === 'string' ? part : (part && typeof part.text === 'string' ? part.text : '')))
      .join(' ')
      .trim();
  } else if (rawTitle && typeof rawTitle === 'object') {
    hadCorruptObject = true;
    if (typeof rawTitle.text === 'string') str = rawTitle.text;
  }
  if (/\[object Object\]/i.test(str)) {
    hadCorruptObject = true;
    str = str.replace(/\[object Object\]/gi, ' ').replace(/^[\s,，:：\-·]+/, '');
  }
  str = str.replace(/\s+/g, ' ').trim();
  if (!str) {
    if (hadCorruptObject) return basenameFromCwd(cwd) || '历史对话';
    return null;
  }
  if (/^We need answer\b/i.test(str)) {
    const quoted = str.match(/"([^"]{2,48})"/);
    if (quoted && quoted[1]) return quoted[1].trim();
    return basenameFromCwd(cwd) || '历史对话';
  }
  // Shorten verbose absolute home-dir paths like "在 /Users/cake/toys/playground/foo ..."
  str = str.replace(/\/(?:Users|home)\/[^/\s]+\/(?:[^/\s]+\/)*([^/\s]+)/g, '$1');
  return str.length > 72 ? `${str.slice(0, 71)}…` : str;
}

export function registerChatAndInteractionsDomain(router, { ctx, gateway, hub, normalizer }) {
  // ---------------- Sessions ----------------
  router.get('/sessions', async (_req, res, { searchParams, peer }) => {
    const args = {};
    if (searchParams.get('workspaceId')) args.workspaceId = searchParams.get('workspaceId');
    if (searchParams.get('includeArchived') === 'true') args.includeArchived = true;
    const [raw, wsSnap] = await Promise.all([
      gateway.call('session/list', args, { peer }),
      readWorkspaceRegistrySnapshot(ctx, gateway, peer).catch(() => ({
        workspaces: [],
        archivedSessionIds: [],
        pinnedSessionIds: [],
      })),
    ]);
    const rawSessions = Array.isArray(raw)
      ? raw
      : (Array.isArray(raw?.items) ? raw.items : (Array.isArray(raw?.sessions) ? raw.sessions : []));

    const sessionToWs = new Map();
    for (const w of wsSnap.workspaces) {
      if (!w.workspaceId) continue;
      for (const sid of w.sessionIds ?? []) {
        sessionToWs.set(String(sid), { workspaceId: w.workspaceId, workspaceName: w.name });
      }
    }
    const archivedSet = new Set(wsSnap.archivedSessionIds);
    const pinnedSet = new Set(wsSnap.pinnedSessionIds);

    let sessions = rawSessions.map((s) => {
      if (!s || typeof s !== 'object') return s;
      const sid = String(s.sessionId ?? s.id ?? '');
      const membership = sessionToWs.get(sid);
      const rawProjTitle = s.projections?.values?.title ?? s.projections?.title ?? s.title ?? s.name;
      const rawCwd = s.cwd ?? s.projections?.values?.workingDirectory ?? s.projections?.workingDirectory;
      const cleanTitle = sanitizeSessionTitle(rawProjTitle, rawCwd);
      return {
        ...s,
        ...(cleanTitle ? { title: cleanTitle } : {}),
        ...(membership ? { workspaceId: membership.workspaceId, workspaceName: membership.workspaceName } : {}),
        archived: Boolean(s.archived || archivedSet.has(sid)),
        pinned: Boolean(s.pinned || pinnedSet.has(sid)),
      };
    });
    const filterWsId = searchParams.get('workspaceId');
    if (filterWsId) {
      sessions = sessions.filter((s) => s && (s.workspaceId === filterWsId || s.cwd === filterWsId));
    }
    if (searchParams.get('includeArchived') !== 'true') {
      sessions = sessions.filter((s) => !s?.archived);
    }
    sendJson(res, 200, { v: 1, sessions });
  }, { domain: 'chat' });

  router.post('/sessions', async (req, res, { peer }) => {
    const body = await readJsonBody(req);
    const createArgs = {};

    // DSH 0.2.x `session/create` accepts EITHER `workspaceId` OR `cwd`, NEVER both!
    // Always prefer an explicit DSH `workspaceId` (auto-ensuring a real Workspace for `cwd`)
    // so new sessions immediately appear grouped in BOTH GrassBag AND Official DSH WebUI (never "未分组")!
    let resolvedWorkspaceId = null;
    if (typeof body.workspaceId === 'string' && body.workspaceId.trim() && !body.workspaceId.startsWith('/')) {
      resolvedWorkspaceId = body.workspaceId.trim();
    } else {
      const targetDir = (typeof body.cwd === 'string' && body.cwd.trim())
        ? body.cwd.trim()
        : (typeof body.workspaceId === 'string' && body.workspaceId.startsWith('/') ? body.workspaceId.trim() : '');
      if (targetDir && body.autoCreateWorkspace !== false) {
        const ws = await ensureExplicitWorkspaceForPath(ctx, gateway, targetDir, { peer });
        if (ws?.workspaceId) {
          resolvedWorkspaceId = ws.workspaceId;
        }
      }
    }

    if (resolvedWorkspaceId) {
      createArgs.workspaceId = resolvedWorkspaceId;
    } else if (typeof body.cwd === 'string' && body.cwd.trim()) {
      createArgs.cwd = body.cwd.trim();
    }
    if (typeof body.sessionId === 'string' && body.sessionId) createArgs.sessionId = body.sessionId;
    const preset = body.agentPreset ?? body.presetId;
    if (typeof preset === 'string' && preset) createArgs.agentPreset = preset;

    const created = await gateway.call('session/create', createArgs, { peer });
    const createdId = created?.sessionId ?? created?.id;
    if (createdId) {
      const postOps = [];
      if (typeof body.title === 'string' && body.title.trim() && gateway.has('session/rename')) {
        postOps.push(
          gateway.call('session/rename', { sessionId: createdId, title: body.title.trim() }, { peer }).catch(() => {}),
        );
      }
      if (typeof body.permission === 'string' && body.permission.trim() && gateway.has('commands/execute')) {
        postOps.push(
          gateway.call('commands/execute', {
            agentId: createdId,
            line: `/permission ${body.permission.trim()}`,
            submittedAttachments: [],
          }, { peer }).catch(() => {}),
        );
      }
      if (typeof body.model === 'string' && body.model.trim() && typeof body.provider === 'string' && body.provider.trim() && gateway.has('session/selectModel')) {
        postOps.push(
          gateway.call('session/selectModel', {
            sessionId: createdId,
            provider: body.provider.trim(),
            model: body.model.trim(),
            ...(typeof body.reasoningEffort === 'string' && body.reasoningEffort.trim()
              ? { reasoningEffort: body.reasoningEffort.trim() }
              : {}),
          }, { peer }).catch(() => {}),
        );
      }
      if (postOps.length > 0) {
        await Promise.all(postOps);
      }
    }
    sendJson(res, 201, {
      v: 1,
      session: {
        ...(created && typeof created === 'object' ? created : { sessionId: createdId }),
        ...(resolvedWorkspaceId ? { workspaceId: resolvedWorkspaceId } : {}),
      },
    });
  }, { domain: 'chat' });

  router.get('/sessions/search', async (_req, res, { searchParams, peer }) => {
    const q = (searchParams.get('q') || '').trim();
    const limit = Math.max(1, Math.min(100, Number(searchParams.get('limit') || 30)));
    if (!q) {
      sendJson(res, 200, { v: 1, results: [] });
      return;
    }
    if (gateway.has('session/search')) {
      try {
        const result = await gateway.call('session/search', { query: q, limit }, { peer });
        const items = Array.isArray(result)
          ? result
          : (result?.items ?? result?.results ?? []);
        sendJson(res, 200, { v: 1, results: items.slice(0, limit) });
        return;
      } catch {
        // Fall through to metadata search when session-query index is disabled/off.
      }
    }
    const raw = await gateway.call('session/list', {}, { peer }).catch(() => []);
    const list = Array.isArray(raw)
      ? raw
      : (Array.isArray(raw?.items) ? raw.items : (Array.isArray(raw?.sessions) ? raw.sessions : []));
    const needle = q.toLowerCase();
    const results = list
      .filter((s) => {
        const title = String(sanitizeSessionTitle(s?.title, s?.cwd) || '').toLowerCase();
        const cwd = String(s?.cwd || '').toLowerCase();
        const sid = String(s?.sessionId ?? s?.id ?? '').toLowerCase();
        return title.includes(needle) || cwd.includes(needle) || sid.includes(needle);
      })
      .slice(0, limit)
      .map((s) => ({
        sessionId: s?.sessionId ?? s?.id,
        title: sanitizeSessionTitle(s?.title, s?.cwd) || '历史对话',
        cwd: s?.cwd ?? '',
        updatedAt: s?.updatedAt ?? s?.createdAt ?? null,
      }));
    sendJson(res, 200, { v: 1, results, fallback: true });
  }, { domain: 'chat' });

  router.patch('/sessions/:id', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const results = {};
    if (typeof body.title === 'string') {
      results.rename = await gateway.call('session/rename', { sessionId: params.id, title: body.title }, { peer });
    }
    if (typeof body.archived === 'boolean') {
      const ep = body.archived ? 'workspace/archiveSession' : 'workspace/unarchiveSession';
      const archiveArgs = body.archived && body.stopActivity !== undefined
        ? { sessionId: params.id, stopActivity: Boolean(body.stopActivity) }
        : { sessionId: params.id };
      results.archive = await gateway.call(ep, archiveArgs, { peer });
    }
    if (typeof body.pinned === 'boolean') {
      const ep = body.pinned ? 'workspace/pinSession' : 'workspace/unpinSession';
      results.pin = await gateway.call(ep, { sessionId: params.id }, { peer });
    }
    sendJson(res, 200, { v: 1, sessionId: params.id, results });
  }, { domain: 'chat' });

  // Normalized paginated turns for mobile ChatList
  router.get('/sessions/:id/turns', async (_req, res, { params, searchParams, peer }) => {
    const limit = Math.max(1, Math.min(200, Number(searchParams.get('limit') || 40)));
    const before = searchParams.get('before') || undefined;
    const isModernPage = usesAddressEnvelope(gateway, 'session/page');
    const args = isModernPage
      ? {
          address: { kind: 'session', sessionId: params.id },
          maxMessages: limit,
          ...(before && Number.isFinite(Number(before)) ? { beforeSeq: Number(before) } : {}),
        }
      : { sessionId: params.id, limit, ...(before ? { before } : {}) };
    const page = await gateway.call('session/page', args, { peer });
    const rawEvents = Array.isArray(page)
      ? page
      : (page?.records ?? page?.events ?? page?.items ?? []);
    const turns = normalizer.normalizeEvents(params.id, rawEvents);
    let projections = null;
    if (searchParams.get('withProjections') !== 'false' && gateway.has('session/projections')) {
      projections = await gateway.call('session/projections', { sessionId: params.id }, { peer }).catch(() => null);
    }
    const rawOldestSeq = (() => {
      for (const item of rawEvents) {
        const ev = item?.type === 'event' && item.event ? item.event : item;
        if (typeof ev?.seq === 'number') return ev.seq;
      }
      return null;
    })();
    const oldestSeq = turns.length > 0 && turns[0].seqStart != null ? turns[0].seqStart : rawOldestSeq;
    sendJson(res, 200, {
      v: 1,
      sessionId: params.id,
      turns,
      hasMore: Boolean(page?.hasMore ?? page?.nextCursor),
      nextCursor: page?.nextCursor ?? (page?.hasMore && oldestSeq != null ? String(oldestSeq) : null),
      ...(projections ? { projections } : {}),
    });
  }, { domain: 'chat' });

  // Lazy full tool output expansion (auto-rehydrates from session/page on cache miss)
  router.get('/sessions/:id/tools/:callId', async (_req, res, { params, peer }) => {
    let cached = normalizer.getToolOutput(params.id, params.callId);
    if (!cached && gateway.has('session/page')) {
      const isModernPage = usesAddressEnvelope(gateway, 'session/page');
      const args = isModernPage
        ? { address: { kind: 'session', sessionId: params.id }, maxMessages: 200 }
        : { sessionId: params.id, limit: 200 };
      const page = await gateway.call('session/page', args, { peer }).catch(() => null);
      const rawEvents = Array.isArray(page)
        ? page
        : (page?.records ?? page?.events ?? page?.items ?? []);
      if (rawEvents.length > 0) {
        normalizer.normalizeEvents(params.id, rawEvents);
        cached = normalizer.getToolOutput(params.id, params.callId);
      }
    }
    if (!cached) {
      throw new GbridgeError(404, 'chat/tool_output_not_found', `tool call "${params.callId}" is not in cache`);
    }
    sendJson(res, 200, { v: 1, tool: cached });
  }, { domain: 'chat' });

  // Unified send / steer / queue / interrupt
  router.post('/sessions/:id/messages', async (req, res, { params, peer }) => {
    // Allow inline base64 images up to 16 MiB so phone camera/screenshot attachments never hit HTTP 413!
    const body = await readJsonBody(req, Math.max(DEFAULT_MAX_UPLOAD_BYTES, 16 * 1024 * 1024));
    const mode = body.mode || 'auto'; // auto | steer | queue | interrupt
    if (mode === 'interrupt' && gateway.has('session/cancel')) {
      await gateway.call('session/cancel', { sessionId: params.id }, { peer }).catch(() => {});
    }
    let promptArgs;
    if (usesContentPromptEnvelope(gateway)) {
      const content = Array.isArray(body.content)
        ? [...body.content]
        : [
            ...(body.text !== undefined && String(body.text).trim().length > 0
              ? [{ type: 'text', text: String(body.text) }]
              : []),
          ];
      // Forward structured @file / @session references cleanly when not already embedded in prompt text.
      if (Array.isArray(body.references) && body.references.length > 0) {
        const refLines = [];
        const existingText = content
          .filter((p) => p && p.type === 'text' && typeof p.text === 'string')
          .map((p) => p.text)
          .join('\n');
        for (const r of body.references) {
          if (!r || typeof r !== 'object') continue;
          const kind = String(r.kind || 'file');
          const refPath = String(r.path || r.id || r.value || '').trim();
          if (!refPath) continue;
          const cleanRef = kind === 'session' ? refPath.replace(/^session:/, '') : refPath;
          const token = kind === 'session' ? `@session:${cleanRef}` : `@${cleanRef}`;
          if (!existingText.includes(token)) {
            refLines.push(kind === 'session' ? `[引用会话: ${r.label || cleanRef} (${cleanRef})]` : `[引用文件: ${cleanRef}]`);
          }
        }
        if (refLines.length > 0) {
          content.unshift({ type: 'text', text: refLines.join('\n') });
        }
      }
      // Forward uploaded attachments cleanly into DSH 0.2.x PromptContentPart blocks!
      if (Array.isArray(body.attachments) && body.attachments.length > 0) {
        const allowedImageMimes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif']);
        const attachmentNotes = [];
        for (const att of body.attachments) {
          if (!att || typeof att !== 'object') continue;
          let mime = String(att.mimeType || att.mediaType || 'application/octet-stream').toLowerCase();
          if (mime === 'image/jpg') mime = 'image/jpeg';
          const name = String(att.name || att.filename || 'attachment');
          const inlineData = typeof att.data === 'string' && att.data.length > 0 ? att.data : null;
          const receiptId = att.receiptId || (att.attachmentId && !String(att.attachmentId).startsWith('att-') ? att.attachmentId : null);
          if (inlineData && allowedImageMimes.has(mime)) {
            content.push({
              type: 'image',
              mediaType: mime,
              data: inlineData,
              name,
            });
          } else if (receiptId) {
            content.push({
              type: 'file',
              receiptId: String(receiptId),
            });
          } else {
            attachmentNotes.push(`[附件: ${name} (${mime})]`);
          }
        }
        if (attachmentNotes.length > 0) {
          content.push({ type: 'text', text: attachmentNotes.join('\n') });
        }
      }
      promptArgs = {
        requestId: body.clientRequestId || body.requestId || randomUUID(),
        sessionId: params.id,
        mode: mode === 'steer' ? 'steer' : 'queue',
        content,
        ...(body.clientTimeZone ? { clientTimeZone: body.clientTimeZone } : {}),
      };
    } else {
      promptArgs = {
        sessionId: params.id,
        ...(body.text !== undefined ? { text: body.text } : {}),
        ...(body.content !== undefined ? { content: body.content } : {}),
        ...(Array.isArray(body.attachments) ? { attachments: body.attachments } : {}),
        ...(Array.isArray(body.references) ? { references: body.references } : {}),
        ...(body.clientRequestId ? { requestId: body.clientRequestId } : {}),
        ...(mode === 'steer' || mode === 'queue' ? { delivery: mode } : {}),
      };
    }
    const result = await gateway.call('session/prompt', promptArgs, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.patch('/sessions/:id/queue', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    let action = body.action;
    if (typeof action === 'string') {
      if (action === 'edit') {
        action = {
          kind: 'edit',
          content: Array.isArray(body.content)
            ? body.content
            : [{ type: 'text', text: String(body.text ?? '') }],
        };
      } else {
        // DSH session/updateQueue Zod enum accepts 'edit' | 'remove' | 'steer' (not 'promote').
        action = { kind: action === 'promote' ? 'steer' : action };
      }
    }
    const reqPayload = body.request && typeof body.request === 'object'
      ? { sessionId: params.id, ...body.request }
      : {
          sessionId: params.id,
          itemId: String(body.itemId ?? body.id ?? ''),
          action,
        };
    const result = await gateway.call('session/updateQueue', { request: reqPayload }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.post('/sessions/:id/cancel', async (_req, res, { params, peer }) => {
    const result = await gateway.call('session/cancel', { sessionId: params.id }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.post('/sessions/:id/fork', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const forkArgs = {
      sessionId: params.id,
      ...(typeof body.atSeq === 'number' && Number.isFinite(body.atSeq) ? { atSeq: body.atSeq } : {}),
      ...(body.allowMigration !== undefined ? { allowMigration: Boolean(body.allowMigration) } : {}),
    };
    const result = await gateway.call('session/fork', forkArgs, { peer });
    const forkedId = result?.sessionId ?? result?.id;
    if (forkedId && typeof body.title === 'string' && body.title.trim() && gateway.has('session/rename')) {
      await gateway.call('session/rename', { sessionId: String(forkedId), title: body.title.trim() }, { peer }).catch(() => {});
    }
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.post('/sessions/:id/commands', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const rawLine = String(body.line ?? body.command ?? '').trim();
    const normalizedLine = rawLine && !rawLine.startsWith('/') ? `/${rawLine}` : rawLine;
    const result = await gateway.call('commands/execute', {
      ...body,
      agentId: params.id,
      sessionId: params.id,
      line: normalizedLine,
      submittedAttachments: Array.isArray(body.submittedAttachments) ? body.submittedAttachments : [],
    }, { peer });
    const inner = result?.result ?? result;
    const isErr = inner?.kind === 'error';
    const text = typeof inner?.text === 'string'
      ? inner.text
      : (typeof result?.text === 'string' ? result.text : '');
    sendJson(res, 200, {
      v: 1,
      ok: !isErr,
      kind: inner?.kind ?? 'success',
      text,
      result,
    });
  }, { domain: 'chat' });

  router.post('/sessions/:id/team', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const result = await gateway.call('agentTeams/setEnabled', {
      agentId: params.id,
      enabled: Boolean(body.enabled),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.get('/sessions/:id/export', async (_req, res, { params, searchParams, peer }) => {
    const wantMarkdown = String(searchParams.get('format') || '').toLowerCase() === 'markdown';
    const exportEp = !wantMarkdown
      ? (gateway.has('session.export')
        ? 'session.export'
        : (gateway.has('session/export') ? 'session/export' : null))
      : null;
    if (exportEp) {
      const result = await gateway.call(exportEp, {
        sessionId: params.id,
        includeDescendants: searchParams.get('includeDescendants') !== 'false',
      }, { peer });
      if (Buffer.isBuffer(result) || result instanceof Uint8Array) {
        sendBinary(res, 200, result, 'application/zip', {
          'content-disposition': `attachment; filename="dsh-session-${params.id}.zip"`,
        });
        return;
      }
      sendJson(res, 200, { v: 1, result });
      return;
    }
    // Clean Markdown transcript export built from session/page when host doesn't mount session.export
    const isModernPage = usesAddressEnvelope(gateway, 'session/page');
    const pageArgs = isModernPage
      ? { address: { kind: 'session', sessionId: params.id }, maxMessages: 200 }
      : { sessionId: params.id, limit: 200 };
    const page = await gateway.call('session/page', pageArgs, { peer });
    const rawEvents = Array.isArray(page)
      ? page
      : (page?.records ?? page?.events ?? page?.items ?? []);
    const turns = normalizer.normalizeEvents(params.id, rawEvents);
    const mdParts = [`# Session Export (${params.id})\n`];
    for (const t of turns) {
      const uText = t.userMessage?.text ?? t.user?.text ?? '';
      if (uText) {
        mdParts.push(`## User\n\n${uText}\n`);
      }
      const asstBlocks = [];
      for (const step of t.steps ?? []) {
        if ((step.kind === 'reasoning' || step.kind === 'thinking') && step.text) {
          asstBlocks.push(`<details><summary>Thinking</summary>\n\n${step.text}\n</details>`);
        } else if (step.kind === 'tool') {
          asstBlocks.push(`> Tool: \`${step.name || step.title || 'tool'}\` (${step.status || 'done'})${step.summary ? ` — ${step.summary}` : ''}`);
        } else if (step.kind === 'notice' && step.text) {
          asstBlocks.push(`> ${step.text}`);
        }
      }
      if (t.assistantText) {
        asstBlocks.push(t.assistantText);
      }
      if (asstBlocks.length > 0) {
        mdParts.push(`## Assistant\n\n${asstBlocks.join('\n\n')}\n`);
      }
    }
    const markdown = mdParts.join('\n');
    sendJson(res, 200, {
      v: 1,
      format: 'markdown',
      sessionId: params.id,
      turnCount: turns.length,
      markdown,
    });
  }, { domain: 'chat' });

  router.put('/sessions/:id/permission', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const preset = String(body.preset ?? body.permission ?? body.id ?? '').trim();
    if (!preset) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'permission preset is required');
    }
    if (gateway.has('commands/execute')) {
      const result = await gateway.call('commands/execute', {
        agentId: params.id,
        line: `/permission ${preset}`,
        submittedAttachments: [],
      }, { peer });
      const inner = result?.result ?? result;
      if (inner?.kind === 'error') {
        throw new GbridgeError(400, 'gbridge/permission_error', String(inner.text || 'failed to set permission preset'));
      }
      sendJson(res, 200, { v: 1, sessionId: params.id, preset, result });
      return;
    }
    throw new GbridgeError(501, 'gbridge/endpoint_unsupported', 'host DSH does not support per-session permission updates');
  }, { domain: 'chat' });

  router.get('/sessions/:id/feedback', async (_req, res, { params, peer }) => {
    if (!gateway.has('messageFeedback/list')) {
      sendJson(res, 200, { v: 1, items: [] });
      return;
    }
    const list = await gateway.call('messageFeedback/list', { sessionId: params.id }, { peer }).catch(() => null);
    const items = Array.isArray(list) ? list : (list?.items ?? list?.records ?? []);
    sendJson(res, 200, { v: 1, items });
  }, { domain: 'chat' });

  router.put('/sessions/:id/feedback', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const messageId = String(body.messageId ?? body.turnId ?? '').trim();
    const rawRating = String(body.rating ?? '').toLowerCase();
    const rating = (rawRating === 'up' || rawRating === 'positive') ? 'positive' : 'negative';
    const note = typeof body.note === 'string'
      ? body.note
      : (typeof body.comment === 'string' ? body.comment : undefined);
    let ifVersion = body.ifVersion !== undefined ? body.ifVersion : null;
    if (body.ifVersion === undefined && gateway.has('messageFeedback/list')) {
      const list = await gateway.call('messageFeedback/list', { sessionId: params.id }, { peer }).catch(() => null);
      const items = Array.isArray(list) ? list : (list?.items ?? list?.records ?? []);
      const existing = items.find((it) => String(it?.messageId ?? '') === messageId);
      if (existing && existing.version !== undefined) {
        ifVersion = existing.version;
      }
    }
    const result = await gateway.call('messageFeedback/put', {
      request: {
        sessionId: params.id,
        messageId,
        rating,
        ifVersion,
        ...(note ? { note } : {}),
        ...(typeof body.category === 'string' && body.category ? { category: body.category } : {}),
      },
    }, { peer });
    if (result && result.ok === false) {
      throw new GbridgeError(400, 'gbridge/feedback_error', String(result.error?.message || result.error || 'failed to save feedback'));
    }
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  router.delete('/sessions/:id/feedback', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const messageId = String(body.messageId ?? body.turnId ?? '').trim();
    let ifVersion = body.ifVersion;
    if (!ifVersion && gateway.has('messageFeedback/list')) {
      const list = await gateway.call('messageFeedback/list', { sessionId: params.id }, { peer });
      const items = Array.isArray(list) ? list : (list?.items ?? list?.records ?? []);
      const existing = items.find((it) => String(it?.messageId ?? '') === messageId);
      if (existing && existing.version !== undefined) {
        ifVersion = existing.version;
      } else {
        sendJson(res, 200, { v: 1, absent: true });
        return;
      }
    }
    const result = await gateway.call('messageFeedback/delete', {
      request: {
        sessionId: params.id,
        messageId,
        ifVersion: String(ifVersion ?? ''),
      },
    }, { peer });
    if (result && result.ok === false) {
      throw new GbridgeError(400, 'gbridge/feedback_error', String(result.error?.message || result.error || 'failed to delete feedback'));
    }
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });

  // ---------------- Composer helpers ----------------
  router.get('/sessions/:id/references', async (_req, res, { params, searchParams, peer }) => {
    const query = searchParams.get('q') || '';
    const [files, sessions] = await Promise.allSettled([
      gateway.has('fileReferences/list') ? gateway.call('fileReferences/list', { agentId: params.id, sessionId: params.id, query }, { peer }) : [],
      gateway.has('sessionReferenceResolver/candidates') ? gateway.call('sessionReferenceResolver/candidates', { agentId: params.id, sessionId: params.id, query }, { peer }) : [],
    ]);
    sendJson(res, 200, {
      v: 1,
      files: files.status === 'fulfilled' ? files.value : [],
      sessions: sessions.status === 'fulfilled' ? sessions.value : [],
    });
  }, { domain: 'chat' });

  router.delete('/sessions/:id', async (_req, res, { params, peer }) => {
    if (gateway.has('session/delete')) {
      const result = await gateway.call('session/delete', { sessionId: params.id }, { peer });
      sendJson(res, 200, { v: 1, deleted: true, result });
      return;
    }
    if (gateway.has('workspace/archiveSession')) {
      const result = await gateway.call('workspace/archiveSession', {
        sessionId: params.id,
        stopActivity: true,
      }, { peer });
      sendJson(res, 200, { v: 1, deleted: true, archived: true, result });
      return;
    }
    throw new GbridgeError(501, 'gbridge/endpoint_unsupported', 'host DSH does not expose session/delete or workspace/archiveSession');
  }, { domain: 'chat' });

  router.get('/commands', async (_req, res, { searchParams, peer }) => {
    let sid = searchParams.get('sessionId') || searchParams.get('agentId');
    if (!sid && gateway.has('session/list')) {
      const list = await gateway.call('session/list', {}, { peer }).catch(() => []);
      const items = Array.isArray(list) ? list : (list?.items ?? list?.sessions ?? []);
      sid = items[0]?.sessionId ?? items[0]?.id ?? null;
    }
    if (!sid) {
      sendJson(res, 200, { v: 1, commands: [] });
      return;
    }
    const args = { agentId: sid, sessionId: sid };
    const ep = gateway.has('commands/catalog') ? 'commands/catalog' : 'commands/list';
    try {
      const commands = await gateway.call(ep, args, { peer });
      sendJson(res, 200, { v: 1, commands });
    } catch (err) {
      const msg = String(err?.message || '');
      if (msg.includes('Unknown agent preset') || msg.includes('resume failed')) {
        sendJson(res, 200, { v: 1, commands: [], unavailablePreset: true });
        return;
      }
      throw err;
    }
  }, { domain: 'chat' });

  router.get('/skills', async (_req, res, { searchParams, peer }) => {
    let sid = searchParams.get('sessionId');
    if (!sid && gateway.has('session/list')) {
      const list = await gateway.call('session/list', {}, { peer }).catch(() => []);
      const items = Array.isArray(list) ? list : (list?.items ?? list?.sessions ?? []);
      sid = items[0]?.sessionId ?? items[0]?.id ?? null;
    }
    if (!sid) {
      sendJson(res, 200, { v: 1, skills: [] });
      return;
    }
    const skills = await gateway.call('skills/list', { sessionId: sid }, { peer });
    sendJson(res, 200, { v: 1, skills });
  }, { domain: 'chat' });

  router.post('/uploads', async (req, res, { searchParams, peer }) => {
    const contentType = String(req.headers['content-type'] || 'application/octet-stream');
    // Treat requests carrying ?filename= as raw binary uploads even if the uploaded file is .json (application/json)!
    const isBinaryUpload = searchParams.has('filename') || !contentType.includes('application/json');
    if (!isBinaryUpload) {
      const body = await readJsonBody(req, DEFAULT_MAX_UPLOAD_BYTES);
      const agentId = body.agentId ?? body.sessionId ?? searchParams.get('sessionId');
      if (!agentId) {
        throw new GbridgeError(400, 'gbridge/validation_error', 'sessionId is required for file upload');
      }
      const uploadReq = body.request && typeof body.request === 'object'
        ? body.request
        : {
            data: String(body.data ?? ''),
            ...(body.filename || body.name ? { name: String(body.filename ?? body.name) } : {}),
          };
      const result = await gateway.call('fileUploads/upload', {
        agentId: String(agentId),
        request: uploadReq,
      }, { peer });
      sendJson(res, 200, {
        v: 1,
        upload: result,
        receiptId: result?.receiptId ?? null,
      });
      return;
    }
    const raw = await readRawBody(req, DEFAULT_MAX_UPLOAD_BYTES);
    const filename = searchParams.get('filename') || 'upload.bin';
    const sessionId = searchParams.get('sessionId') || searchParams.get('agentId') || undefined;
    if (!sessionId) {
      throw new GbridgeError(400, 'gbridge/validation_error', 'query param sessionId is required for binary upload');
    }
    const result = await gateway.call('fileUploads/upload', {
      agentId: String(sessionId),
      request: {
        data: raw.toString('base64'),
        name: filename,
      },
    }, { peer });
    sendJson(res, 200, {
      v: 1,
      upload: result,
      receiptId: result?.receiptId ?? null,
    });
  }, { domain: 'files' });

  router.get('/attachments/:id', async (_req, res, { params, searchParams, peer }) => {
    const sessionId = searchParams.get('sessionId') || '';
    const mediaType = searchParams.get('mediaType') || 'application/octet-stream';
    const bytes = Number(searchParams.get('bytes') || 0);
    const width = Number(searchParams.get('width') || 0);
    const height = Number(searchParams.get('height') || 0);
    const usesReqEnvelope = (() => {
      try {
        const desc = gateway.typert?.local?.get?.('session/attachment');
        const firstParam = desc?.parameters?.[0];
        const props = firstParam?.codec?.jsonSchema?.properties;
        return Boolean(
          firstParam?.name === 'request' ||
          props?.attachment ||
          props?.request,
        );
      } catch {
        return false;
      }
    })();
    let attachmentObj = {
      attachmentId: params.id,
      mediaType,
      ...(bytes > 0 ? { bytes } : {}),
      ...(width > 0 ? { width } : {}),
      ...(height > 0 ? { height } : {}),
    };
    if (usesReqEnvelope && sessionId && bytes <= 0 && gateway.has('session/page')) {
      try {
        const isModernPage = usesAddressEnvelope(gateway, 'session/page');
        const pageArgs = isModernPage
          ? { address: { kind: 'session', sessionId }, maxMessages: 120 }
          : { sessionId, limit: 120 };
        const page = await gateway.call('session/page', pageArgs, { peer });
        const events = Array.isArray(page) ? page : (page?.records ?? page?.events ?? page?.items ?? []);
        for (const rawEv of events) {
          const ev = rawEv?.type === 'event' && rawEv.event ? rawEv.event : rawEv;
          const parts = ev?.data?.content ?? ev?.data?.message?.content ?? ev?.content ?? [];
          if (!Array.isArray(parts)) continue;
          for (const p of parts) {
            const att = p?.attachment ?? (p?.attachmentId ? p : null);
            if (att && String(att.attachmentId) === params.id) {
              attachmentObj = { ...attachmentObj, ...att };
              break;
            }
          }
        }
      } catch {}
    }
    const callArgs = usesReqEnvelope
      ? { request: { sessionId, attachment: attachmentObj } }
      : { attachmentId: params.id, ...(sessionId ? { sessionId } : {}) };
    const result = await gateway.call('session/attachment', callArgs, { peer });
    let rawBuf = null;
    if (Buffer.isBuffer(result) || result instanceof Uint8Array) {
      rawBuf = Buffer.from(result);
    } else if (Buffer.isBuffer(result?.data) || result?.data instanceof Uint8Array) {
      rawBuf = Buffer.from(result.data);
    } else if (typeof result?.data === 'string' && result.data.length > 0) {
      rawBuf = Buffer.from(result.data, 'base64');
    }
    if (rawBuf) {
      sendBinary(res, 200, rawBuf, result?.attachment?.mediaType || attachmentObj.mediaType || mediaType);
      return;
    }
    sendJson(res, 200, { v: 1, attachment: result });
  }, { domain: 'chat' });

  // ---------------- Interactions (Approvals, Questions, Cordis Run) & Goals ----------------
  router.get('/interactions/pending', async (_req, res) => {
    sendJson(res, 200, { v: 1, items: hub.listPendingInteractions() });
  }, { domain: 'chat' });

  router.post('/interactions/:id/respond', async (req, res, { params }) => {
    const body = await readJsonBody(req);
    const settled = await hub.respondInteraction(params.id, body);
    if (!settled) {
      throw new GbridgeError(404, 'interactions/not_found', `pending interaction "${params.id}" not found or already settled`);
    }
    sendJson(res, 200, { v: 1, ...settled });
  }, { domain: 'chat' });

  router.get('/permissions/catalog', async (_req, res, { peer }) => {
    const catalog = await gateway.call('permissionPresets/catalog', {}, { peer });
    sendJson(res, 200, { v: 1, catalog });
  }, { domain: 'chat' });

  router.get('/sessions/:id/goals', async (_req, res, { params, peer }) => {
    try {
      const goal = await gateway.call('goals/get', { agentId: params.id }, { peer });
      sendJson(res, 200, { v: 1, goal: goal ?? null });
    } catch (err) {
      const msg = String(err?.message || '');
      const code = String(err?.code || '');
      if (msg.includes('Unknown agent preset') || msg.includes('resume failed')) {
        sendJson(res, 200, { v: 1, goal: null, unavailablePreset: true });
        return;
      }
      if (
        code === 'GOAL_AGENT_NOT_LIVE' ||
        msg.includes('GOAL_AGENT_NOT_LIVE') ||
        msg.includes('not live') ||
        msg.includes('not active')
      ) {
        // Cold/historical sessions store durable goal snapshots in `session/projections` under `values.goal`.
        let projGoal = null;
        if (gateway.has('session/projections')) {
          const proj = await gateway
            .call('session/projections', { request: { sessionId: params.id } }, { peer })
            .catch(() => gateway.call('session/projections', { sessionId: params.id }, { peer }).catch(() => null));
          projGoal = proj?.values?.goal ?? proj?.goal ?? null;
        }
        sendJson(res, 200, { v: 1, goal: projGoal });
        return;
      }
      throw err;
    }
  }, { domain: 'chat' });

  router.post('/sessions/:id/goals', async (req, res, { params, peer }) => {
    const body = await readJsonBody(req);
    const action = body.action || 'create'; // create | edit | pause | resume | complete | clear
    const allowed = new Set(['create', 'edit', 'pause', 'resume', 'complete', 'clear']);
    if (!allowed.has(action)) {
      throw new GbridgeError(400, 'gbridge/validation_error', `invalid goal action "${action}"`);
    }
    if (action === 'create') {
      const rawObj = String(body.request?.objective ?? body.objective ?? body.title ?? '').trim();
      const rawCriteria = String(body.criteria ?? '').trim();
      const objective = rawCriteria && !rawObj.includes(rawCriteria)
        ? `${rawObj}\n验收标准：${rawCriteria}`
        : rawObj;
      if (!objective) {
        throw new GbridgeError(400, 'gbridge/validation_error', 'goal objective is required');
      }
      const maxRoundsRaw = body.request?.maxGoalRounds ?? body.maxGoalRounds;
      const maxGoalRounds = Number.isFinite(Number(maxRoundsRaw)) && Number(maxRoundsRaw) > 0
        ? Math.floor(Number(maxRoundsRaw))
        : undefined;
      const result = await gateway.call('goals/create', {
        agentId: params.id,
        request: {
          objective,
          ...(maxGoalRounds !== undefined ? { maxGoalRounds } : {}),
        },
      }, { peer });
      sendJson(res, 200, { v: 1, result });
      return;
    }

    // Mutating actions require `ref: { id, revision }`; auto-resolve from live goals/get if caller didn't supply exact revision.
    let ref = body.ref && typeof body.ref === 'object' && body.ref.id && typeof body.ref.revision === 'number'
      ? { id: String(body.ref.id), revision: Number(body.ref.revision) }
      : null;
    if (!ref && gateway.has('goals/get')) {
      const current = await gateway.call('goals/get', { agentId: params.id }, { peer }).catch(() => null);
      if (current === null || current === undefined) {
        throw new GbridgeError(404, 'goals/not_found', 'no active goal found on this session');
      }
      if (current.id && typeof current.revision === 'number') {
        ref = { id: String(current.id), revision: Number(current.revision) };
      }
    }

    if (action === 'edit') {
      const requestObj = {};
      const nextObj = String(body.request?.objective ?? body.objective ?? body.title ?? '').trim();
      if (nextObj) requestObj.objective = nextObj;
      const maxRoundsRaw = body.request?.maxGoalRounds ?? body.maxGoalRounds;
      if (Number.isFinite(Number(maxRoundsRaw)) && Number(maxRoundsRaw) > 0) {
        requestObj.maxGoalRounds = Math.floor(Number(maxRoundsRaw));
      }
      const result = await gateway.call('goals/edit', {
        agentId: params.id,
        ...(ref ? { ref } : {}),
        request: requestObj,
      }, { peer });
      sendJson(res, 200, { v: 1, result });
      return;
    }

    const result = await gateway.call(`goals/${action}`, {
      agentId: params.id,
      ...(ref ? { ref } : {}),
    }, { peer });
    sendJson(res, 200, { v: 1, result });
  }, { domain: 'chat' });
}
