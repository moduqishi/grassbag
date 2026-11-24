/**
 * Normalizes raw DSH session events & history pages into GrassBag's stable
 * `NormalizedTurn` contract, shielding the Flutter UI from upstream DSH
 * `session-format` changes, and detects secret ranges for UI masking.
 */

const SECRET_PATTERNS = [
  /\bsk-ant-[A-Za-z0-9_-]{16,}\b/g,
  /\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{22,}\b/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{30,}\b/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]{0,16384}?-----END [A-Z ]*PRIVATE KEY-----/g,
];

export function detectSecretRanges(text) {
  if (typeof text !== 'string' || text.length < 16) return [];
  const raw = [];
  for (const baseRegex of SECRET_PATTERNS) {
    const regex = new RegExp(baseRegex.source, baseRegex.flags);
    let m;
    while ((m = regex.exec(text)) !== null) {
      const start = m.index;
      const end = start + m[0].length;
      const visiblePrefix = Math.min(8, Math.max(0, m[0].length - 6));
      raw.push({ start, end, visiblePrefix });
    }
  }
  if (raw.length <= 1) return raw;
  raw.sort((a, b) => a.start - b.start || b.end - a.end);
  const merged = [raw[0]];
  for (let i = 1; i < raw.length; i++) {
    const prev = merged[merged.length - 1];
    const cur = raw[i];
    if (cur.start <= prev.end) {
      if (cur.end > prev.end) prev.end = cur.end;
    } else {
      merged.push(cur);
    }
  }
  return merged;
}

export function previewLine(text, maxChars = 160) {
  if (typeof text !== 'string') return '';
  const first = text.trim().split(/\r?\n/, 1)[0] || '';
  return first.length > maxChars ? `${first.slice(0, maxChars - 1)}…` : first;
}

export function summarizeTool(name, args, output) {
  const tool = String(name || 'tool');
  let target = '';
  if (args && typeof args === 'object') {
    const candidate = args.command ?? args.cmd ?? args.file_path ?? args.path ?? args.pattern ?? args.query ?? args.url ?? args.description;
    if (typeof candidate === 'string') target = previewLine(candidate, 100);
  }
  const title = target ? `${tool} · ${target}` : tool;
  const outStr = typeof output === 'string'
    ? output
    : output !== undefined && output !== null
      ? safeJsonPreview(output, 400)
      : '';
  const summary = previewLine(outStr, 220);
  return { title, summary, hasFullOutput: outStr.length > 0 };
}

/**
 * Extract structured human-readable error info matching `@deepseek-ai/dsh-client-ui-chat`
 * (`endFailure` + `displayFailure`) across DSH v0.1.x & v0.2.x event shapes.
 */
export function extractFailureInfo(reason, data = {}) {
  if (reason && typeof reason === 'object') {
    const kind = String(reason.kind || reason.status || '');
    if (kind === 'error') {
      const err = reason.error && typeof reason.error === 'object' ? reason.error : reason;
      const code = typeof err.code === 'string' ? err.code : undefined;
      const msg = formatErrorObject(err);
      return { code, message: msg || '执行过程中发生未知错误' };
    }
    if (kind === 'aborted') {
      const inner = reason.reason && typeof reason.reason === 'object' ? reason.reason : null;
      if (inner?.kind === 'hook' && inner?.reason === 'deepseek-account/signed-out') {
        return { code: 'ACCOUNT_SIGNED_OUT', message: 'DeepSeek 账号已退出登录，当前回复已中止。' };
      }
      if (inner?.message) {
        return { code: inner.code ? String(inner.code) : 'ABORTED', message: String(inner.message) };
      }
      return null;
    }
    if (kind === 'interrupted') {
      return { code: 'INTERRUPTED', message: 'DSH 进程在本轮回复完成前意外退出。' };
    }
  }
  if (typeof reason === 'string' && reason === 'error') {
    const err = data?.error;
    return {
      code: typeof err?.code === 'string' ? err.code : (typeof data?.code === 'string' ? data.code : undefined),
      message: formatErrorObject(err ?? data) || '执行过程中发生错误',
    };
  }
  if (data?.error) {
    return {
      code: typeof data.error?.code === 'string' ? data.error.code : (typeof data.code === 'string' ? data.code : undefined),
      message: formatErrorObject(data.error) || String(data.error),
    };
  }
  return null;
}

function formatErrorObject(err) {
  if (!err) return '';
  if (typeof err === 'string') return err.trim();
  if (typeof err !== 'object') return String(err);
  const parts = [];
  const main = err.message ?? err.reason ?? err.detail ?? err.summary ?? err.error;
  if (typeof main === 'string' && main.trim()) parts.push(main.trim());
  if (typeof err.reason === 'string' && err.reason.trim() && !parts.includes(err.reason.trim())) {
    parts.push(err.reason.trim());
  }
  if (typeof err.status === 'number' && !parts.some((p) => p.includes(String(err.status)))) {
    parts.push(`HTTP ${err.status}`);
  }
  if (err.cause) {
    const c = formatErrorObject(err.cause);
    if (c && !parts.includes(c)) parts.push(`原因: ${c}`);
  }
  if (parts.length > 0) return parts.join(' · ');
  return safeJsonPreview(err, 400);
}

function safeJsonPreview(val, max) {
  try {
    const s = JSON.stringify(val);
    return s.length > max ? `${s.slice(0, max)}…` : s;
  } catch {
    return String(val).slice(0, max);
  }
}

const MAX_TOOL_CACHE_BYTES = 32 * 1024 * 1024;
const MAX_SINGLE_TOOL_OUTPUT_CHARS = 512 * 1024;

/**
 * Per-session incremental state reducer + byte-bounded LRU tool output store for lazy expansion.
 */
export class SessionNormalizer {
  constructor({ maxCachedToolOutputs = 1000, maxCacheBytes = MAX_TOOL_CACHE_BYTES } = {}) {
    this.maxCachedToolOutputs = maxCachedToolOutputs;
    this.maxCacheBytes = maxCacheBytes;
    this.toolOutputs = new Map(); // `${sessionId}:${callId}` -> { record, bytes }
    this.toolOutputBytes = 0;
    this.turnStats = new Map(); // sessionId -> { startedAt, outputChars, phase, target }
  }

  cacheToolOutput(sessionId, callId, record) {
    if (!sessionId || !callId) return;
    const key = `${sessionId}:${callId}`;
    const prevEntry = this.toolOutputs.get(key);
    if (prevEntry) {
      this.toolOutputBytes -= prevEntry.bytes;
      this.toolOutputs.delete(key);
    }
    let normalizedRecord = record;
    if (record && typeof record.output === 'string' && record.output.length > MAX_SINGLE_TOOL_OUTPUT_CHARS) {
      normalizedRecord = {
        ...record,
        output: `${record.output.slice(0, MAX_SINGLE_TOOL_OUTPUT_CHARS)}\n…[已截断，原始长度 ${record.output.length} 字符]`,
        truncated: true,
      };
    }
    const bytes = Math.max(128, (typeof normalizedRecord?.output === 'string' ? normalizedRecord.output.length * 2 : 512));
    this.toolOutputs.set(key, { record: normalizedRecord, bytes });
    this.toolOutputBytes += bytes;
    while (
      (this.toolOutputs.size > this.maxCachedToolOutputs || this.toolOutputBytes > this.maxCacheBytes) &&
      this.toolOutputs.size > 1
    ) {
      const oldestKey = this.toolOutputs.keys().next().value;
      const oldest = this.toolOutputs.get(oldestKey);
      this.toolOutputBytes -= oldest?.bytes ?? 0;
      this.toolOutputs.delete(oldestKey);
    }
  }

  getToolOutput(sessionId, callId) {
    const key = `${sessionId}:${callId}`;
    const entry = this.toolOutputs.get(key);
    if (!entry) return null;
    // Refresh LRU order on read
    this.toolOutputs.delete(key);
    this.toolOutputs.set(key, entry);
    return entry.record ?? null;
  }

  /**
   * Normalize a raw DSH session page / event list into GrassBag `NormalizedTurn[]`.
   * Tolerant across DSH 0.1.x and 0.2.x event shapes.
   * When `incremental: true`, single live stream events stay `status: 'streaming'`
   * (never prematurely closing a live turn on `user/message` or mid-turn `assistant/message`)
   * and reuse `activeTurnId` so all events in one live turn share the same `turnId`.
   */
  normalizeEvents(sessionId, rawEvents = [], { incremental = false, activeTurnId = null } = {}) {
    const turns = [];
    let current = null;
    const toolIndex = new Map();

    const promotePreToolNarration = (turn, seq) => {
      if (!turn || typeof turn.assistantText !== 'string') return;
      const trimmed = turn.assistantText.trim();
      if (!trimmed) return;
      turn.steps.push({
        kind: 'reasoning',
        id: `narration-${seq ?? 0}-${turn.steps.length}`,
        text: trimmed,
        collapsedPreview: previewLine(trimmed),
      });
      turn.assistantText = '';
    };

    const restoreFallbackNarration = (turn) => {
      if (!turn || turn.status === 'streaming') return;
      if (typeof turn.assistantText === 'string' && turn.assistantText.trim().length > 0) return;
      for (let idx = turn.steps.length - 1; idx >= 0; idx -= 1) {
        const s = turn.steps[idx];
        if (s && s.kind === 'reasoning' && typeof s.id === 'string' && s.id.startsWith('narration-') && s.text) {
          turn.assistantText = s.text;
          turn.steps.splice(idx, 1);
          return;
        }
      }
    };

    const ensureTurn = (seedId, seq) => {
      if (!current) {
        current = {
          turnId: (incremental && activeTurnId) ? activeTurnId : (seedId || `turn-${turns.length + 1}`),
          seqStart: seq ?? 0,
          seqEnd: seq ?? 0,
          status: incremental ? 'streaming' : 'completed',
          steps: [],
          assistantText: '',
          deliverables: [],
        };
        turns.push(current);
      }
      if (typeof seq === 'number') current.seqEnd = Math.max(current.seqEnd, seq);
      return current;
    };

    for (let i = 0; i < rawEvents.length; i++) {
      const rawEntry = rawEvents[i];
      if (!rawEntry || typeof rawEntry !== 'object') continue;
      // Real DSH 0.2.2-rc.5 SessionHistoryRecord wraps events as `{ type: 'event', event: SessionWireEvent }`.
      const ev = rawEntry.type === 'event' && rawEntry.event && typeof rawEntry.event === 'object'
        ? rawEntry.event
        : rawEntry;
      // Skip compaction / pruner surface replacement entries so compacted history never duplicates messages.
      if (ev.surfaceOp !== undefined && ev.surfaceOp !== 'append') {
        continue;
      }
      const type = ev.type || ev.kind || '';
      const seq = typeof ev.seq === 'number' ? ev.seq : i;
      const data = ev.data ?? ev.payload ?? ev;

      if (type === 'user/message' || type === 'user_message' || (type === 'message' && data?.role === 'user')) {
        const msg = data?.message && typeof data.message === 'object' ? data.message : data;
        const text = extractText(msg);
        const contentAttachments = Array.isArray(msg?.content)
          ? msg.content
              .filter((b) => b && typeof b === 'object' && (b.type === 'image' || b.type === 'file'))
              .map((b) => ({
                type: b.type,
                ...(b.attachment && typeof b.attachment === 'object' ? b.attachment : {}),
                ...(b.name ? { name: b.name } : {}),
                ...(b.mediaType ? { mimeType: b.mediaType } : {}),
              }))
          : [];
        const mergedAttachments = Array.isArray(msg?.attachments) && msg.attachments.length > 0
          ? msg.attachments
          : contentAttachments;
        if (!isHumanUserMessage(msg, data, text) && mergedAttachments.length === 0) {
          continue;
        }
        // In real DSH 0.2.x, `turn/start` precedes `user/message` in the same turn.
        // Attach the human prompt to that freshly-started turn instead of leaving an empty turn.
        const canReuseCurrent = current &&
          !current.userMessage &&
          current.steps.length === 0 &&
          !current.assistantText;
        if (!canReuseCurrent) {
          if (current && current.status === 'streaming' && !incremental) {
            current.status = 'completed';
          }
          current = null;
        }
        const turn = ensureTurn(ev.turnId || ev.id || `turn-${seq}`, seq);
        turn.userMessage = {
          id: msg?.id || ev.id || `msg-${seq}`,
          text,
          attachments: mergedAttachments,
          references: Array.isArray(msg?.references) ? msg.references : [],
          maskedRanges: detectSecretRanges(text),
          createdAt: typeof ev.time === 'number' ? ev.time : Date.now(),
        };
        if (!canReuseCurrent && !incremental) {
          turn.status = 'completed';
        }
        continue;
      }

      if (type === 'turn/start' || type === 'turn_start') {
        if (current && current.status === 'streaming') {
          current.status = 'completed';
          restoreFallbackNarration(current);
        }
        if (!current || current.assistantText || current.steps.length > 0 || current.userMessage) {
          current = null;
        }
        const turn = ensureTurn(data?.turnId || (data?.turn !== undefined ? `turn-${data.turn}` : ev.id), seq);
        turn.status = 'streaming';
        continue;
      }

      if (type === 'tool/call' || type === 'tool_call') {
        const turn = ensureTurn(ev.turnId, seq);
        promotePreToolNarration(turn, seq);
        const callId = String(data?.callId || data?.id || `call-${seq}-${turn.steps.length}`);
        let parsedArgs = data?.arguments ?? data?.input ?? {};
        if (typeof parsedArgs === 'string') {
          try { parsedArgs = JSON.parse(parsedArgs); } catch {}
        }
        const { title, summary } = summarizeTool(data?.name, parsedArgs);
        const existing = toolIndex.get(callId);
        if (!existing) {
          const step = {
            kind: 'tool',
            callId,
            name: String(data?.name || 'tool'),
            title,
            status: 'running',
            summary,
            hasFullOutput: false,
          };
          turn.steps.push(step);
          toolIndex.set(callId, step);
        }
        this.cacheToolOutput(sessionId, callId, {
          callId,
          name: String(data?.name || 'tool'),
          args: parsedArgs,
          output: null,
          status: 'running',
        });
        continue;
      }

      if (type === 'assistant/message' || type === 'assistant_message' || (type === 'message' && data?.role === 'assistant')) {
        const turn = ensureTurn(ev.turnId, seq);
        const msg = data?.message && typeof data.message === 'object' ? data.message : data;
        const msgId = msg?.id ?? data?.messageId ?? ev.id;
        if (typeof msgId === 'string' && msgId.trim()) {
          turn.assistantMessageId = msgId.trim();
        }
        const blocks = Array.isArray(msg?.content) ? msg.content : (Array.isArray(data?.content) ? data.content : null);
        if (blocks) {
          for (const b of blocks) {
            if (!b || typeof b !== 'object') continue;
            if (b.type === 'reasoning' || b.type === 'thinking') {
              const rText = String(b.text ?? b.thinking ?? '');
              if (rText) {
                turn.steps.push({
                  kind: 'reasoning',
                  id: b.id || `reason-${seq}-${turn.steps.length}`,
                  text: rText,
                  collapsedPreview: previewLine(rText),
                });
              }
            } else if (b.type === 'tool-call' || b.type === 'tool_use' || b.type === 'toolCall') {
              promotePreToolNarration(turn, seq);
              const callId = String(b.id || b.callId || `call-${seq}-${turn.steps.length}`);
              let bArgs = b.arguments ?? b.input ?? {};
              if (typeof bArgs === 'string') {
                try { bArgs = JSON.parse(bArgs); } catch {}
              }
              const { title, summary } = summarizeTool(b.name, bArgs);
              if (!toolIndex.has(callId)) {
                const step = {
                  kind: 'tool',
                  callId,
                  name: String(b.name || 'tool'),
                  title,
                  status: 'running',
                  summary,
                  hasFullOutput: false,
                };
                turn.steps.push(step);
                toolIndex.set(callId, step);
              }
              this.cacheToolOutput(sessionId, callId, {
                callId,
                name: String(b.name || 'tool'),
                args: bArgs,
                output: null,
                status: 'running',
              });
            } else if (b.type === 'text') {
              const chunk = String(b.text ?? '');
              if (chunk) {
                if (turn.assistantText && !turn.assistantText.endsWith('\n') && !chunk.startsWith('\n')) {
                  turn.assistantText += '\n\n';
                }
                turn.assistantText += chunk;
              }
            }
          }
        } else {
          const t = extractText(msg);
          if (t) {
            if (turn.assistantText && !turn.assistantText.endsWith('\n') && !t.startsWith('\n')) {
              turn.assistantText += '\n\n';
            }
            turn.assistantText += t;
          }
        }
        const msgUsage = data?.usage ?? msg?.usage;
        if (msgUsage && typeof msgUsage === 'object') {
          const stepIn = Number(msgUsage.uncachedInputTokens ?? msgUsage.inputTokens ?? msgUsage.promptTokens ?? 0);
          const stepOut = Number(msgUsage.outputTokens ?? msgUsage.completionTokens ?? 0);
          const stepCacheRead = msgUsage.cacheReadTokens !== undefined ? Number(msgUsage.cacheReadTokens) : 0;
          const stepCacheWrite = msgUsage.cacheWriteTokens !== undefined ? Number(msgUsage.cacheWriteTokens) : 0;
          const stepDur = msgUsage.durationMs !== undefined ? Number(msgUsage.durationMs) : 0;
          const prev = turn.usage;
          turn.usage = {
            inputTokens: (prev?.inputTokens ?? 0) + stepIn,
            outputTokens: (prev?.outputTokens ?? 0) + stepOut,
            ...((prev?.cacheReadTokens !== undefined || msgUsage.cacheReadTokens !== undefined)
              ? { cacheReadTokens: (prev?.cacheReadTokens ?? 0) + stepCacheRead }
              : {}),
            ...((prev?.cacheWriteTokens !== undefined || msgUsage.cacheWriteTokens !== undefined)
              ? { cacheWriteTokens: (prev?.cacheWriteTokens ?? 0) + stepCacheWrite }
              : {}),
            ...((prev?.durationMs !== undefined || msgUsage.durationMs !== undefined)
              ? { durationMs: (prev?.durationMs ?? 0) + stepDur }
              : {}),
          };
        }
        continue;
      }

      if (type === 'tool/result' || type === 'tool_result' || (type === 'message' && data?.role === 'tool')) {
        const turn = ensureTurn(ev.turnId, seq);
        const msg = data?.message && typeof data.message === 'object' ? data.message : data;
        const callId = String(
          msg?.toolCallId ??
          msg?.callId ??
          msg?.source?.callId ??
          data?.callId ??
          data?.toolCallId ??
          msg?.id ??
          `call-${seq}`,
        );
        const rawOut = msg?.content ?? data?.output ?? data?.result ?? data?.content ?? '';
        const output = Array.isArray(rawOut) ? extractText({ content: rawOut }) : rawOut;
        const isError = Boolean(data?.error || msg?.isError || data?.isError);
        const prev = this.getToolOutput(sessionId, callId);
        const existing = toolIndex.get(callId);
        const toolName = existing?.name || prev?.name || String(msg?.name || data?.name || 'tool');
        const effectiveArgs = prev?.args ?? data?.arguments ?? {};
        const { title, summary, hasFullOutput } = summarizeTool(toolName, effectiveArgs, output);
        const effectiveHasFull = hasFullOutput || (isError && String(output || '').trim().length > 0);
        if (existing) {
          existing.status = isError ? 'error' : 'ok';
          if (summary) existing.summary = summary;
          existing.hasFullOutput = effectiveHasFull;
          if (typeof data?.durationMs === 'number') existing.durationMs = data.durationMs;
          if (typeof data?.subagentSessionId === 'string') existing.subagentSessionId = data.subagentSessionId;
        } else {
          const step = {
            kind: 'tool',
            callId,
            name: toolName,
            title,
            status: isError ? 'error' : 'ok',
            summary,
            hasFullOutput: effectiveHasFull,
          };
          turn.steps.push(step);
          toolIndex.set(callId, step);
        }
        this.cacheToolOutput(sessionId, callId, {
          callId,
          name: toolName,
          args: effectiveArgs,
          output: isError && !output && data?.error ? formatErrorObject(data.error) : output,
          ...(data?.meta ? { meta: data.meta } : {}),
          status: isError ? 'error' : 'ok',
        });
        continue;
      }

      if (type === 'error' || type === 'turn/error' || type === 'step/error' || type === 'assistant/error') {
        const turn = ensureTurn(ev.turnId, seq);
        const fail = extractFailureInfo('error', data);
        if (fail) {
          turn.status = 'error';
          turn.errorMessage = fail.message;
          if (fail.code) turn.errorCode = fail.code;
          turn.steps.push({
            kind: 'notice',
            level: 'error',
            text: fail.code ? `[${fail.code}] ${fail.message}` : fail.message,
          });
        }
        continue;
      }

      if (type === 'turn/end' || type === 'turn_end') {
        const turn = ensureTurn(data?.turnId, seq);
        const reason = typeof data?.reason === 'object' && data?.reason !== null
          ? (data.reason.kind || data.reason.status)
          : (data?.reason || data?.status);
        const fail = extractFailureInfo(data?.reason, data);
        turn.status = reason === 'cancelled' || (reason === 'aborted' && !fail)
          ? 'cancelled'
          : (reason === 'error' || reason === 'interrupted' || Boolean(fail) || Boolean(data?.error))
            ? 'error'
            : 'completed';
        if (fail) {
          turn.errorMessage = fail.message;
          if (fail.code) turn.errorCode = fail.code;
          const noticeText = fail.code ? `[${fail.code}] ${fail.message}` : fail.message;
          const alreadyHasErrorNotice = turn.steps.some((s) => s.kind === 'notice' && s.level === 'error' && s.text === noticeText);
          if (!alreadyHasErrorNotice) {
            turn.steps.push({ kind: 'notice', level: 'error', text: noticeText });
          }
        }
        if (data?.usage && typeof data.usage === 'object') {
          turn.usage = {
            inputTokens: Number(data.usage.uncachedInputTokens ?? data.usage.inputTokens ?? data.usage.promptTokens ?? 0),
            outputTokens: Number(data.usage.outputTokens ?? data.usage.completionTokens ?? 0),
            ...(data.usage.cacheReadTokens !== undefined ? { cacheReadTokens: Number(data.usage.cacheReadTokens) } : {}),
            ...(data.usage.cacheWriteTokens !== undefined ? { cacheWriteTokens: Number(data.usage.cacheWriteTokens) } : {}),
            ...(data.usage.durationMs !== undefined ? { durationMs: Number(data.usage.durationMs) } : {}),
          };
        }
        if (Array.isArray(data?.deliverables)) {
          turn.deliverables = data.deliverables;
        }
        restoreFallbackNarration(turn);
        current = null;
        continue;
      }
    }

    for (const t of turns) {
      restoreFallbackNarration(t);
    }

    return turns.filter((t) => Boolean(t.userMessage) || t.steps.length > 0 || t.assistantText.trim().length > 0 || Boolean(t.errorMessage));
  }

  /**
   * Compute live Dock Stack activity telemetry from an incremental stream chunk.
   */
  observeStreamChunk(sessionId, chunk) {
    let stat = this.turnStats.get(sessionId);
    const now = Date.now();
    if (!stat || chunk?.type === 'turn/start' || chunk?.type === 'snapshot') {
      stat = { startedAt: now, outputChars: 0, phase: 'thinking', target: undefined };
      this.turnStats.set(sessionId, stat);
    }
    const chunkTextLen = () => {
      if (Array.isArray(chunk?.texts)) return chunk.texts.reduce((a, s) => a + String(s ?? '').length, 0);
      return String(chunk?.text ?? chunk?.delta ?? '').length;
    };
    const ctype = String(chunk?.type || '');
    if (ctype === 'reasoning-delta' || ctype === 'reasoning-chunks' || chunk?.kind === 'reasoning') {
      stat.phase = 'thinking';
      stat.outputChars += chunkTextLen();
    } else if (ctype === 'text-delta' || ctype === 'text-chunks' || chunk?.kind === 'text') {
      stat.phase = 'streaming';
      stat.outputChars += chunkTextLen();
    } else if (ctype === 'tool-call-delta' || ctype === 'tool-call-chunks' || chunk?.kind === 'tool-call') {
      stat.phase = 'tool';
      if (chunk?.name) stat.target = String(chunk.name);
      stat.outputChars += chunkTextLen();
    }
    const elapsedMs = Math.max(1, now - stat.startedAt);
    const estTokens = stat.outputChars / 3.5;
    const tps = elapsedMs >= 200 ? Number(((estTokens * 1000) / elapsedMs).toFixed(1)) : undefined;
    return {
      phase: stat.phase,
      ...(stat.target ? { target: stat.target } : {}),
      ...(tps !== undefined ? { tps } : {}),
      elapsedMs,
    };
  }

  clearSessionStat(sessionId) {
    this.turnStats.delete(sessionId);
  }
}

function isHumanUserMessage(msg, data, text) {
  const source = msg?.source ?? data?.source;
  if (source && typeof source === 'object') {
    const kind = String(source.kind || '');
    return kind === 'user' || kind === 'retry';
  }
  const trimmed = String(text || '').trim();
  if (!trimmed) return false;
  if (
    trimmed.startsWith('<system-reminder>') ||
    trimmed.startsWith('<openviking-context') ||
    trimmed.startsWith('Time sampled while preparing turn')
  ) {
    return false;
  }
  return true;
}

function extractText(data) {
  if (typeof data === 'string') return data;
  if (typeof data?.text === 'string') return data.text;
  if (typeof data?.content === 'string') return data.content;
  if (Array.isArray(data?.content)) {
    return data.content
      .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text)
      .join('');
  }
  return '';
}
