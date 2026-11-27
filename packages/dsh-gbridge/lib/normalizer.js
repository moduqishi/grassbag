/**
 * Normalizes raw DSH session events & history pages into GrassBag's stable
 * `NormalizedTurn` contract, shielding the Flutter UI from upstream DSH
 * `session-format` changes, and detects secret ranges for UI masking.
 */

import { findMalformedContentBlocks } from './content-contract.js';
import { extractTopStackFrame } from './diagnostics.js';

const SECRET_QUICK_TRIGGER = /(?:sk-|gh[pousr]_|github_pat_|AKIA|AIza|-----BEGIN )/;

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
  if (!SECRET_QUICK_TRIGGER.test(text)) return [];
  const raw = [];
  for (const regex of SECRET_PATTERNS) {
    regex.lastIndex = 0;
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
  if (typeof text !== 'string' || text.length === 0) return '';
  let start = 0;
  const len = text.length;
  while (start < len && text.charCodeAt(start) <= 32) start++;
  if (start >= len) return '';
  const scanLimit = Math.min(len, start + maxChars + 2);
  let end = scanLimit;
  for (let i = start; i < scanLimit; i++) {
    const c = text.charCodeAt(i);
    if (c === 10 || c === 13) {
      end = i;
      break;
    }
  }
  while (end > start && text.charCodeAt(end - 1) <= 32) end--;
  const lineLen = end - start;
  if (lineLen <= maxChars && end < len && (text.charCodeAt(end) === 10 || text.charCodeAt(end) === 13)) {
    return text.slice(start, end);
  }
  if (lineLen > maxChars) {
    return `${text.slice(start, start + maxChars - 1)}…`;
  }
  if (end === scanLimit && end < len) {
    const nextC = text.charCodeAt(end);
    if (nextC !== 10 && nextC !== 13) {
      return `${text.slice(start, start + maxChars - 1)}…`;
    }
  }
  return text.slice(start, end);
}

function tryParseJsonObject(val) {
  if (val && typeof val === 'object' && !Array.isArray(val)) return val;
  if (typeof val !== 'string') return null;
  const trimmed = val.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null;
  try {
    const parsed = JSON.parse(trimmed);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

const PHONE_KEY_LABELS = {
  back: '返回键',
  home: '主屏键',
  recents: '最近任务',
  enter: '回车键',
  notifications: '通知栏',
  quick_settings: '快捷设置',
};

function extractToolTarget(tool, args, parsedOut) {
  const n = tool.toLowerCase();
  const a = args && typeof args === 'object' ? args : {};
  if (n.startsWith('phone_')) {
    switch (n) {
      case 'phone_open': {
        const app = a.appName ?? a.app ?? parsedOut?.opened ?? parsedOut?.label ?? a.package ?? a.packageName ?? a.url ?? parsedOut?.package;
        return typeof app === 'string' ? previewLine(app, 60) : '';
      }
      case 'phone_tap':
      case 'phone_long_press': {
        const lbl = a.label ?? a.text ?? a.desc ?? a.description ?? parsedOut?.label;
        if (typeof lbl === 'string' && lbl.trim()) return previewLine(lbl, 50);
        if (a.nodeId !== undefined && a.nodeId !== null && String(a.nodeId).trim()) {
          return `元素 ${a.nodeId}`;
        }
        if (a.x !== undefined && a.y !== undefined) return `(${a.x}, ${a.y})`;
        return '';
      }
      case 'phone_swipe': {
        const dirMap = { up: '向上滑动', down: '向下滑动', left: '向左滑动', right: '向右滑动' };
        if (typeof a.direction === 'string' && dirMap[a.direction.toLowerCase()]) {
          return dirMap[a.direction.toLowerCase()];
        }
        if (a.x1 !== undefined && a.y1 !== undefined && a.x2 !== undefined && a.y2 !== undefined) {
          return `(${a.x1},${a.y1}) → (${a.x2},${a.y2})`;
        }
        return '滑动屏幕';
      }
      case 'phone_type': {
        const txt = a.text ?? a.value ?? a.input;
        return typeof txt === 'string' && txt.trim() ? `「${previewLine(txt, 40)}」` : '';
      }
      case 'phone_key': {
        const key = String(a.action ?? a.key ?? '').toLowerCase();
        return PHONE_KEY_LABELS[key] || previewLine(String(a.action ?? a.key ?? ''), 40);
      }
      case 'phone_intent': {
        const kind = a.kind ?? a.target ?? a.action ?? a.uri ?? a.url;
        return typeof kind === 'string' ? previewLine(kind, 60) : '';
      }
      case 'phone_wait': {
        if (typeof a.ms === 'number') return a.ms >= 1000 ? `${(a.ms / 1000).toFixed(1)}s` : `${a.ms}ms`;
        if (typeof a.seconds === 'number') return `${a.seconds}s`;
        return '等待界面稳定';
      }
      case 'phone_handoff': {
        const msg = a.message ?? a.reason ?? a.prompt;
        return typeof msg === 'string' && msg.trim() ? previewLine(msg, 60) : '等待人工确认';
      }
      case 'phone_return_app': {
        const sum = a.summary ?? a.reason ?? a.message;
        return typeof sum === 'string' && sum.trim() ? previewLine(sum, 60) : '回到 GrassBag';
      }
      case 'phone_screen': {
        const lbl = parsedOut?.appLabel ?? parsedOut?.appName ?? parsedOut?.package ?? parsedOut?.packageName;
        return typeof lbl === 'string' && lbl.trim() ? previewLine(lbl, 50) : '读取当前界面';
      }
      case 'phone_screenshot':
        return '截取当前屏幕';
      case 'phone_apps':
        return typeof a.query === 'string' && a.query.trim()
          ? `搜索「${previewLine(a.query, 40)}」`
          : '已安装应用列表';
      default:
        break;
    }
  }
  const candidate = a.command ??
    a.cmd ??
    a.file_path ??
    a.filePath ??
    a.path ??
    a.pattern ??
    a.glob ??
    a.regex ??
    a.query ??
    a.url ??
    a.description ??
    a.title ??
    a.name ??
    a.target;
  return typeof candidate === 'string' ? previewLine(candidate, 100) : '';
}

function summarizeHumanToolOutput(tool, outStr, parsedOut) {
  if (!parsedOut) return previewLine(outStr, 220);
  if (parsedOut.ok === false || parsedOut.blocked === true || parsedOut.error) {
    const errText = typeof parsedOut.hint === 'string' && parsedOut.hint.trim()
      ? parsedOut.hint
      : (typeof parsedOut.error === 'string'
        ? parsedOut.error
        : (parsedOut.error?.message ?? parsedOut.message ?? parsedOut.reason ?? '执行失败'));
    return previewLine(String(errText), 180);
  }
  const n = tool.toLowerCase();
  if (n.startsWith('phone_')) {
    if (n === 'phone_open') {
      const opened = parsedOut.opened ?? parsedOut.label ?? parsedOut.appName;
      return opened ? `已打开 ${previewLine(String(opened), 40)}` : (parsedOut.ok ? '已打开应用' : '');
    }
    if (n === 'phone_screenshot') {
      if (parsedOut.width && parsedOut.height) return `${parsedOut.width}×${parsedOut.height}`;
      return parsedOut.ok ? '截屏完成' : '';
    }
    if (n === 'phone_screen') {
      const app = parsedOut.appLabel ?? parsedOut.appName ?? parsedOut.package ?? parsedOut.packageName ?? '';
      const count = Array.isArray(parsedOut.elements)
        ? parsedOut.elements.length
        : (Array.isArray(parsedOut.nodes)
          ? parsedOut.nodes.length
          : (typeof parsedOut.count === 'number'
            ? parsedOut.count
            : (typeof parsedOut.nodeCount === 'number' ? parsedOut.nodeCount : null)));
      if (app && count !== null) return `${previewLine(String(app), 32)} · ${count} 元素`;
      if (app) return previewLine(String(app), 40);
      if (count !== null) return `${count} 个元素`;
      return parsedOut.ok ? '已读取界面' : '';
    }
    if (n === 'phone_apps') {
      const count = Array.isArray(parsedOut.apps) ? parsedOut.apps.length : (typeof parsedOut.count === 'number' ? parsedOut.count : null);
      return count !== null ? `${count} 个应用` : (parsedOut.ok ? '已列出' : '');
    }
    if (n === 'phone_return_app') {
      return parsedOut.ok ? '已返回应用' : '';
    }
    const msg = parsedOut.message ?? parsedOut.summary ?? parsedOut.status;
    if (typeof msg === 'string' && msg.trim()) return previewLine(msg, 60);
    return parsedOut.ok ? '已完成' : '';
  }
  const msg = parsedOut.summary ?? parsedOut.message;
  if (typeof msg === 'string' && msg.trim()) return previewLine(msg, 160);
  return '';
}

function extractUpstreamPresentation(presentation) {
  if (!presentation || typeof presentation !== 'object') return { title: '', summary: '' };
  const record = presentation.record && typeof presentation.record === 'object' ? presentation.record : null;
  const rawTitle = presentation.title ?? presentation.label ?? record?.title ?? record?.label;
  const rawSummary = presentation.summary ?? presentation.caption ?? presentation.subtitle ?? record?.summary ?? record?.caption;
  return {
    title: typeof rawTitle === 'string' && rawTitle.trim() ? previewLine(rawTitle, 120) : '',
    summary: typeof rawSummary === 'string' && rawSummary.trim() ? previewLine(rawSummary, 220) : '',
  };
}

export function summarizeTool(name, args, output, preParsedOut = undefined, presentation = null) {
  const tool = String(name || 'tool');
  const parsedOut = preParsedOut !== undefined ? preParsedOut : tryParseJsonObject(output);
  const hasOutput = typeof output === 'string'
    ? output.length > 0
    : output !== undefined && output !== null;
  const outStr = parsedOut
    ? ''
    : typeof output === 'string'
      ? output
      : hasOutput
        ? safeJsonPreview(output, 400)
        : '';
  // Prefer upstream DSH tool presentation metadata when available to minimize shadow-rendering drift.
  const upstream = extractUpstreamPresentation(presentation ?? parsedOut?.presentation);
  const target = upstream.title ? '' : extractToolTarget(tool, args, parsedOut);
  const title = upstream.title || (target ? `${tool} · ${target}` : tool);
  const summary = upstream.summary || summarizeHumanToolOutput(tool, outStr, parsedOut);
  return { title, summary, hasFullOutput: hasOutput };
}

/**
 * Extract structured human-readable error info matching `@deepseek-ai/dsh-client-ui-chat`
 * (`endFailure` + `displayFailure`) across DSH v0.1.x & v0.2.x event shapes.
 * When DSH collapses an unexpected exception to `[UNKNOWN]`, enriches the message with
 * concrete tool name, malformed content-block shape, endpoint, and stack location.
 */
export function extractFailureInfo(reason, data = {}, context = null) {
  let base = null;
  if (reason && typeof reason === 'object') {
    const kind = String(reason.kind || reason.status || '');
    if (kind === 'error') {
      const err = reason.error && typeof reason.error === 'object' ? reason.error : reason;
      const code = typeof err.code === 'string' ? err.code : undefined;
      const msg = formatErrorObject(err);
      base = { code, message: msg || '执行过程中发生未知错误' };
    } else if (kind === 'aborted') {
      const inner = reason.reason && typeof reason.reason === 'object' ? reason.reason : null;
      if (inner?.kind === 'hook' && inner?.reason === 'deepseek-account/signed-out') {
        return { code: 'ACCOUNT_SIGNED_OUT', message: 'DeepSeek 账号已退出登录，当前回复已中止。' };
      }
      if (inner?.message) {
        return { code: inner.code ? String(inner.code) : 'ABORTED', message: String(inner.message) };
      }
      return null;
    } else if (kind === 'interrupted') {
      return { code: 'INTERRUPTED', message: 'DSH 进程在本轮回复完成前意外退出。' };
    }
  }
  if (!base && typeof reason === 'string' && reason === 'error') {
    const err = data?.error;
    base = {
      code: typeof err?.code === 'string' ? err.code : (typeof data?.code === 'string' ? data.code : undefined),
      message: formatErrorObject(err ?? data) || '执行过程中发生错误',
    };
  }
  if (!base && data?.error) {
    base = {
      code: typeof data.error?.code === 'string' ? data.error.code : (typeof data.code === 'string' ? data.code : undefined),
      message: formatErrorObject(data.error) || String(data.error),
    };
  }
  if (!base) return null;
  return enrichFailureInfo(base, context);
}

function enrichFailureInfo(fail, context) {
  if (!fail || !context || typeof context !== 'object') return fail;
  const codeUpper = String(fail.code || '').toUpperCase();
  const isOpaque = !codeUpper || codeUpper === 'UNKNOWN' || codeUpper === 'INTERNAL_ERROR';
  const mentionsAttachment = /attachmentid|attachment\b|reading ['"]attachment/i.test(fail.message);
  const malformed = Array.isArray(context.malformedBlocks) ? context.malformedBlocks : [];
  const lastTool = typeof context.lastToolName === 'string' && context.lastToolName.trim()
    ? context.lastToolName.trim()
    : '';
  const extras = [];

  if (malformed.length > 0 && (isOpaque || mentionsAttachment)) {
    const latest = malformed[malformed.length - 1];
    const shapeStr = `{type:"${latest.blockType || 'unknown'}", keys:[${(latest.blockKeys || []).join(',')}]}`;
    const toolLabel = latest.toolName || lastTool || 'tool';
    const hint = latest.reason === 'inline_provider_image_block_forbidden' || latest.reason === 'missing_image_attachment' || latest.reason === 'missing_attachment_id'
      ? '缺少 attachment.attachmentId'
      : latest.reason;
    const diag = `检测到工具 ${toolLabel} 返回了异常内容块 ${shapeStr}（${hint}）`;
    if (!fail.message.includes(toolLabel) || !fail.message.includes('异常内容块')) {
      extras.push(diag);
    }
  } else if (mentionsAttachment && lastTool) {
    const diag = `疑似工具 ${lastTool} 返回了未入库的图像块（缺少 attachment.attachmentId）`;
    if (!fail.message.includes(lastTool)) extras.push(diag);
  } else if (isOpaque && lastTool && !fail.message.includes(lastTool)) {
    extras.push(`最近调用工具: ${lastTool}`);
  }

  if (extras.length === 0) return fail;
  return {
    ...fail,
    message: `${fail.message} · ${extras.join(' · ')}`,
    ...(malformed.length > 0 ? { malformedBlock: malformed[malformed.length - 1] } : {}),
    ...(lastTool ? { toolName: lastTool } : {}),
  };
}

function formatErrorObject(err, depth = 0, seen = new Set()) {
  if (!err || depth > 5) return '';
  if (typeof err === 'string') return err.trim();
  if (typeof err !== 'object') return String(err);
  if (seen.has(err)) return '';
  seen.add(err);
  const parts = [];
  const main = err.message ?? err.reason ?? err.detail ?? err.summary ?? err.error;
  const errName = typeof err.name === 'string' && err.name && err.name !== 'Error' ? err.name.trim() : '';
  if (typeof main === 'string' && main.trim()) {
    const trimmed = main.trim();
    parts.push(errName && !trimmed.startsWith(errName) ? `${errName}: ${trimmed}` : trimmed);
  } else if (errName) {
    parts.push(errName);
  }
  if (typeof err.reason === 'string' && err.reason.trim() && !parts.some((p) => p.includes(err.reason.trim()))) {
    parts.push(err.reason.trim());
  }
  const details = err.details && typeof err.details === 'object' ? err.details : null;
  const toolName = err.toolName ?? err.tool ?? details?.toolName ?? details?.tool;
  if (typeof toolName === 'string' && toolName.trim() && !parts.some((p) => p.includes(toolName.trim()))) {
    parts.push(`工具: ${toolName.trim()}`);
  }
  const blockType = err.blockType ?? details?.blockType ?? details?.shape?.type;
  const blockKeys = err.blockKeys ?? details?.blockKeys ?? details?.shape?.keys;
  if (typeof blockType === 'string' && blockType.trim()) {
    const shapeDesc = Array.isArray(blockKeys) && blockKeys.length > 0
      ? `{type:"${blockType.trim()}", keys:[${blockKeys.join(',')}]}`
      : `{type:"${blockType.trim()}"}`;
    if (!parts.some((p) => p.includes(shapeDesc))) parts.push(`块形状: ${shapeDesc}`);
  }
  const endpoint = err.endpoint ?? details?.endpoint;
  if (typeof endpoint === 'string' && endpoint.trim() && !parts.some((p) => p.includes(endpoint.trim()))) {
    parts.push(`接口: ${endpoint.trim()}`);
  }
  if (typeof err.status === 'number' && !parts.some((p) => p.includes(String(err.status)))) {
    parts.push(`HTTP ${err.status}`);
  }
  if (err.cause) {
    const c = formatErrorObject(err.cause, depth + 1, seen);
    if (c && !parts.includes(c)) parts.push(`原因: ${c}`);
  }
  const codeUpper = String(err.code || '').toUpperCase();
  if ((codeUpper === 'UNKNOWN' || !codeUpper) && typeof err.stack === 'string') {
    const frame = extractTopStackFrame(err.stack);
    if (frame && !parts.some((p) => p.includes(frame))) {
      parts.push(`位置: ${frame}`);
    }
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
    this.sessionFailureContexts = new Map(); // sessionId -> { lastToolName, malformedBlocks: [] }
  }

  _ensureFailureContext(sessionId) {
    if (!sessionId) return null;
    let ctx = this.sessionFailureContexts.get(sessionId);
    if (!ctx) {
      ctx = { lastToolName: '', malformedBlocks: [] };
      this.sessionFailureContexts.set(sessionId, ctx);
    }
    return ctx;
  }

  recordContractViolation(sessionId, violation) {
    const ctx = this._ensureFailureContext(sessionId || '_global');
    if (!ctx || !violation) return;
    if (violation.toolName) ctx.lastToolName = String(violation.toolName);
    ctx.malformedBlocks.push({
      toolName: String(violation.toolName || ctx.lastToolName || 'tool'),
      blockType: String(violation.shape?.type ?? violation.blockType ?? 'unknown'),
      blockKeys: Array.isArray(violation.shape?.keys)
        ? violation.shape.keys
        : (Array.isArray(violation.blockKeys) ? violation.blockKeys : []),
      reason: String(violation.reason || 'invalid_content_block'),
    });
    if (ctx.malformedBlocks.length > 8) ctx.malformedBlocks.shift();
  }

  getSessionFailureContext(sessionId) {
    return (sessionId ? this.sessionFailureContexts.get(sessionId) : null)
      ?? this.sessionFailureContexts.get('_global')
      ?? null;
  }

  cacheToolOutput(sessionId, callId, record) {
    if (!sessionId || !callId) return;
    const key = `${sessionId}:${callId}`;
    const prevEntry = this.toolOutputs.get(key);
    let normalizedRecord = record;
    if (
      prevEntry &&
      record &&
      record.output == null &&
      record.status === 'running' &&
      (prevEntry.record?.output != null || prevEntry.record?.status !== 'running')
    ) {
      // Never wipe an already-completed or populated tool output with a replayed/late tool_call placeholder.
      normalizedRecord = {
        ...prevEntry.record,
        args: prevEntry.record?.args ?? record.args,
      };
    }
    if (prevEntry) {
      this.toolOutputBytes -= prevEntry.bytes;
      this.toolOutputs.delete(key);
    }
    let bytes = 256;
    if (normalizedRecord && typeof normalizedRecord.output === 'string') {
      if (normalizedRecord.output.length > MAX_SINGLE_TOOL_OUTPUT_CHARS) {
        normalizedRecord = {
          ...normalizedRecord,
          output: `${normalizedRecord.output.slice(0, MAX_SINGLE_TOOL_OUTPUT_CHARS)}\n…[已截断，原始长度 ${normalizedRecord.output.length} 字符]`,
          truncated: true,
        };
      }
      bytes = Math.max(128, normalizedRecord.output.length * 2);
    } else if (normalizedRecord && normalizedRecord.output != null) {
      let jsonLen = 512;
      try {
        const encoded = JSON.stringify(normalizedRecord.output);
        jsonLen = encoded ? encoded.length : 512;
        if (jsonLen > MAX_SINGLE_TOOL_OUTPUT_CHARS) {
          normalizedRecord = {
            ...normalizedRecord,
            output: `${encoded.slice(0, MAX_SINGLE_TOOL_OUTPUT_CHARS)}\n…[已截断，原始长度 ${jsonLen} 字符]`,
            truncated: true,
          };
          jsonLen = normalizedRecord.output.length;
        }
      } catch (_jsonErr) {
        // Non-JSON-serializable or circular tool output: retain conservative byte estimate.
      }
      bytes = Math.max(256, jsonLen * 2);
    }
    if (normalizedRecord && normalizedRecord.args != null) {
      let argsLen = 0;
      if (typeof normalizedRecord.args === 'string') {
        argsLen = normalizedRecord.args.length;
        if (argsLen > MAX_SINGLE_TOOL_OUTPUT_CHARS) {
          normalizedRecord = {
            ...normalizedRecord,
            args: `${normalizedRecord.args.slice(0, MAX_SINGLE_TOOL_OUTPUT_CHARS)}\n…[已截断，原始长度 ${argsLen} 字符]`,
            truncated: true,
          };
          argsLen = normalizedRecord.args.length;
        }
      } else {
        try {
          const encodedArgs = JSON.stringify(normalizedRecord.args);
          argsLen = encodedArgs ? encodedArgs.length : 0;
          if (argsLen > MAX_SINGLE_TOOL_OUTPUT_CHARS) {
            normalizedRecord = {
              ...normalizedRecord,
              args: `${encodedArgs.slice(0, MAX_SINGLE_TOOL_OUTPUT_CHARS)}\n…[已截断，原始长度 ${argsLen} 字符]`,
              truncated: true,
            };
            argsLen = normalizedRecord.args.length;
          }
        } catch (_jsonErr) {
          // Non-JSON-serializable tool args: keep default size estimate.
        }
      }
      bytes += argsLen * 2;
    }
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
    const toolStartTimes = new Map();
    const turnDiagnostics = new WeakMap();
    const getTurnDiag = (turn) => {
      let diag = turnDiagnostics.get(turn);
      if (!diag) {
        diag = { lastToolName: '', malformedBlocks: [] };
        turnDiagnostics.set(turn, diag);
      }
      return diag;
    };
    const mergedFailureContext = (turn) => {
      const local = getTurnDiag(turn);
      const live = incremental ? this.getSessionFailureContext(sessionId) : null;
      return {
        lastToolName: local.lastToolName || live?.lastToolName || '',
        malformedBlocks: local.malformedBlocks.length > 0
          ? local.malformedBlocks
          : (live?.malformedBlocks ?? []),
      };
    };

    const promoteIntermediateProse = (turn, seq) => {
      if (!turn || typeof turn.assistantText !== 'string') return;
      const trimmed = turn.assistantText.trim();
      if (!trimmed) return;
      turn.steps.push({
        kind: 'reasoning',
        role: 'prose',
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
        if (s && s.kind === 'reasoning' && (s.role === 'prose' || (typeof s.id === 'string' && s.id.startsWith('narration-'))) && s.text) {
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
                ...(b.mimeType ? { mimeType: b.mimeType } : {}),
                ...(typeof b.data === 'string' && b.data ? { data: b.data } : {}),
                ...(typeof b.base64 === 'string' && b.base64 ? { base64: b.base64 } : {}),
                ...(typeof b.url === 'string' && b.url ? { url: b.url } : {}),
                ...(typeof b.uri === 'string' && b.uri ? { uri: b.uri } : {}),
                ...(typeof b.image === 'string' && b.image ? { data: b.image } : {}),
                ...(b.source && typeof b.source === 'object' && typeof b.source.data === 'string'
                  ? { data: b.source.data, ...(b.source.media_type ? { mimeType: b.source.media_type } : {}) }
                  : {}),
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
        promoteIntermediateProse(turn, seq);
        const callId = String(data?.callId || data?.id || `call-${seq}-${turn.steps.length}`);
        let parsedArgs = data?.arguments ?? data?.input ?? {};
        if (typeof parsedArgs === 'string') {
          try { parsedArgs = JSON.parse(parsedArgs); } catch (_invalidJsonArgs) { /* keep raw string args */ }
        }
        const toolName = String(data?.name || 'tool');
        getTurnDiag(turn).lastToolName = toolName;
        if (incremental && sessionId) this._ensureFailureContext(sessionId).lastToolName = toolName;
        const { title, summary } = summarizeTool(toolName, parsedArgs, undefined, undefined, data?.presentation);
        const existing = toolIndex.get(callId);
        if (typeof ev.time === 'number' && !toolStartTimes.has(callId)) {
          toolStartTimes.set(callId, ev.time);
        }
        if (!existing) {
          const step = {
            kind: 'tool',
            callId,
            name: toolName,
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
          name: toolName,
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
                promoteIntermediateProse(turn, seq);
                turn.steps.push({
                  kind: 'reasoning',
                  id: b.id || `reason-${seq}-${turn.steps.length}`,
                  text: rText,
                  collapsedPreview: previewLine(rText),
                });
              }
            } else if (b.type === 'tool-call' || b.type === 'tool_use' || b.type === 'toolCall') {
              promoteIntermediateProse(turn, seq);
              const callId = String(b.id || b.callId || `call-${seq}-${turn.steps.length}`);
              let bArgs = b.arguments ?? b.input ?? {};
              if (typeof bArgs === 'string') {
                try { bArgs = JSON.parse(bArgs); } catch (_invalidJsonArgs) { /* keep raw string args */ }
              }
              const bToolName = String(b.name || 'tool');
              getTurnDiag(turn).lastToolName = bToolName;
              if (incremental && sessionId) this._ensureFailureContext(sessionId).lastToolName = bToolName;
              const { title, summary } = summarizeTool(bToolName, bArgs, undefined, undefined, b.presentation);
              if (typeof ev.time === 'number' && !toolStartTimes.has(callId)) {
                toolStartTimes.set(callId, ev.time);
              }
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
              const existingCached = this.getToolOutput(sessionId, callId);
              if (!existingCached || (existingCached.output == null && existingCached.status === 'running')) {
                this.cacheToolOutput(sessionId, callId, {
                  callId,
                  name: String(b.name || 'tool'),
                  args: bArgs,
                  output: existingCached?.output ?? null,
                  status: existingCached?.status ?? 'running',
                });
              }
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
        const parsedOut = tryParseJsonObject(output);
        const isError = Boolean(
          data?.error ||
          msg?.isError ||
          data?.isError ||
          parsedOut?.ok === false ||
          parsedOut?.blocked === true,
        );
        const prev = this.getToolOutput(sessionId, callId);
        const existing = toolIndex.get(callId);
        const toolName = existing?.name || prev?.name || String(msg?.name || data?.name || 'tool');
        const effectiveArgs = prev?.args ?? data?.arguments ?? {};
        const diag = getTurnDiag(turn);
        diag.lastToolName = toolName;
        if (incremental && sessionId) this._ensureFailureContext(sessionId).lastToolName = toolName;
        if (Array.isArray(rawOut)) {
          const malformed = findMalformedContentBlocks(rawOut);
          for (const bad of malformed) {
            const entry = {
              toolName,
              blockType: bad.shape.type,
              blockKeys: bad.shape.keys,
              reason: bad.reason,
            };
            diag.malformedBlocks.push(entry);
            if (incremental && sessionId) this.recordContractViolation(sessionId, entry);
          }
        }
        const { title, summary, hasFullOutput } = summarizeTool(
          toolName,
          effectiveArgs,
          output,
          parsedOut,
          data?.presentation ?? msg?.presentation,
        );
        const effectiveHasFull = hasFullOutput || (isError && String(output || '').trim().length > 0);
        if (existing) {
          existing.status = isError ? 'error' : 'ok';
          const canUpgradeTitle = title &&
            title !== toolName &&
            (!existing.title ||
              existing.title === toolName ||
              (toolName.toLowerCase().startsWith('phone_') && title !== existing.title));
          if (canUpgradeTitle) {
            existing.title = title;
          }
          if (summary) existing.summary = summary;
          existing.hasFullOutput = effectiveHasFull;
          const startedAt = toolStartTimes.get(callId);
          const inferredDur = typeof data?.durationMs === 'number'
            ? data.durationMs
            : (typeof ev.time === 'number' && typeof startedAt === 'number' && ev.time >= startedAt
                ? Math.round(ev.time - startedAt)
                : undefined);
          if (typeof inferredDur === 'number') existing.durationMs = inferredDur;
          if (typeof data?.subagentSessionId === 'string') existing.subagentSessionId = data.subagentSessionId;
        } else {
          const startedAt = toolStartTimes.get(callId);
          const inferredDur = typeof data?.durationMs === 'number'
            ? data.durationMs
            : (typeof ev.time === 'number' && typeof startedAt === 'number' && ev.time >= startedAt
                ? Math.round(ev.time - startedAt)
                : undefined);
          const step = {
            kind: 'tool',
            callId,
            name: toolName,
            title,
            status: isError ? 'error' : 'ok',
            summary,
            hasFullOutput: effectiveHasFull,
            ...(typeof inferredDur === 'number' ? { durationMs: inferredDur } : {}),
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
        const fail = extractFailureInfo('error', data, mergedFailureContext(turn));
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
        const fail = extractFailureInfo(data?.reason, data, mergedFailureContext(turn));
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
          const prevDur = turn.usage?.durationMs;
          const nextDur = data.usage.durationMs !== undefined ? Number(data.usage.durationMs) : prevDur;
          turn.usage = {
            inputTokens: Number(data.usage.uncachedInputTokens ?? data.usage.inputTokens ?? data.usage.promptTokens ?? 0),
            outputTokens: Number(data.usage.outputTokens ?? data.usage.completionTokens ?? 0),
            ...(data.usage.cacheReadTokens !== undefined ? { cacheReadTokens: Number(data.usage.cacheReadTokens) } : {}),
            ...(data.usage.cacheWriteTokens !== undefined ? { cacheWriteTokens: Number(data.usage.cacheWriteTokens) } : {}),
            ...(nextDur !== undefined ? { durationMs: nextDur } : {}),
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
   * Uses CJK-aware token estimation and pauses/resets decode timing across tool
   * execution & idle gaps so live `tps` reflects real LLM decode speed.
   */
  observeStreamChunk(sessionId, chunk) {
    let stat = this.turnStats.get(sessionId);
    const now = Date.now();
    const ctype = String(chunk?.type || '');
    if (!stat || ctype === 'turn/start' || ctype === 'snapshot') {
      stat = {
        startedAt: now,
        activeDecodeMs: 0,
        lastDecodeAt: 0,
        estTokens: 0,
        phase: 'thinking',
        target: undefined,
      };
      this.turnStats.set(sessionId, stat);
    } else if (ctype === 'step/start') {
      stat.activeDecodeMs = 0;
      stat.lastDecodeAt = 0;
      stat.estTokens = 0;
      stat.target = undefined;
      if (stat.phase === 'tool') stat.phase = 'thinking';
    }
    if (ctype === 'reasoning-delta' || ctype === 'reasoning-chunks' || chunk?.kind === 'reasoning') {
      if (stat.phase === 'tool') {
        stat.activeDecodeMs = 0;
        stat.lastDecodeAt = 0;
        stat.estTokens = 0;
        stat.target = undefined;
      }
      stat.phase = 'thinking';
      recordStreamDecode(stat, extractStreamChunkText(chunk), now);
    } else if (ctype === 'text-delta' || ctype === 'text-chunks' || chunk?.kind === 'text') {
      if (stat.phase === 'tool') {
        stat.activeDecodeMs = 0;
        stat.lastDecodeAt = 0;
        stat.estTokens = 0;
        stat.target = undefined;
      }
      stat.phase = 'streaming';
      recordStreamDecode(stat, extractStreamChunkText(chunk), now);
    } else if (ctype === 'tool-call-delta' || ctype === 'tool-call-chunks' || chunk?.kind === 'tool-call') {
      stat.phase = 'tool';
      stat.lastDecodeAt = 0;
      if (chunk?.name) stat.target = String(chunk.name);
    }
    const elapsedMs = Math.max(1, now - stat.startedAt);
    const tps = (stat.phase !== 'tool' && stat.activeDecodeMs >= 200 && stat.estTokens >= 1)
      ? Math.round(((stat.estTokens * 1000) / stat.activeDecodeMs) * 10) / 10
      : undefined;
    return {
      phase: stat.phase,
      ...(stat.target ? { target: stat.target } : {}),
      ...(tps !== undefined ? { tps } : {}),
      elapsedMs,
    };
  }

  clearSessionStat(sessionId) {
    this.turnStats.delete(sessionId);
    this.sessionFailureContexts.delete(sessionId);
  }
}

function extractStreamChunkText(chunk) {
  if (Array.isArray(chunk?.texts)) return chunk.texts.map((s) => String(s ?? '')).join('');
  return String(chunk?.text ?? chunk?.delta ?? '');
}

function estimateStreamTokens(text) {
  if (!text) return 0;
  let cjk = 0;
  let other = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) >= 0x2e80) cjk += 1;
    else other += 1;
  }
  return cjk / 1.5 + other / 3.8;
}

function recordStreamDecode(stat, text, now) {
  const tok = estimateStreamTokens(text);
  if (tok <= 0) return;
  if (stat.lastDecodeAt > 0) {
    const dt = now - stat.lastDecodeAt;
    // Ignore multi-second pauses (e.g. tool execution or brief stall) so decode speed stays honest.
    if (dt > 0 && dt <= 1500) {
      stat.activeDecodeMs += Math.min(dt, 600);
    }
  }
  stat.lastDecodeAt = now;
  stat.estTokens += tok;
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
