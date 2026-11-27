/**
 * Lightweight structured diagnostics & explicit teardown helpers for `dsh-gbridge`.
 * Replaces opaque silent `catch {}` blocks with either contextual warning/debug logs
 * or explicitly documented best-effort cleanup, and extracts concise error metadata
 * (code, error class, stack frame) for `[UNKNOWN]` failure enrichment.
 */

const MEANINGFUL_ERROR_NAMES = new Set([
  'TypeError',
  'RangeError',
  'ReferenceError',
  'SyntaxError',
  'URIError',
  'AttachmentError',
  'LlmError',
  'GbridgeError',
  'AbortError',
]);

/**
 * Extract the first relevant stack frame (skipping `node:` internals) in compact `file:line` form.
 */
export function extractTopStackFrame(stack) {
  if (typeof stack !== 'string' || !stack) return '';
  const lines = stack.split('\n');
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('at ')) continue;
    if (line.includes('node:internal/') || line.includes('(node:')) continue;
    const match = /([A-Za-z0-9@._-]+\/[A-Za-z0-9@._/-]+:\d+)(?::\d+)?/.exec(line);
    if (match) {
      const segs = match[1].split('/');
      return segs.length > 3 ? segs.slice(-3).join('/') : match[1];
    }
    return line.slice(3, 90);
  }
  return '';
}

/**
 * Compact, safe description of an arbitrary thrown value for logs & diagnostics.
 */
export function describeError(err) {
  if (err == null) return { message: 'unknown error' };
  if (typeof err === 'string') return { message: err.trim() || 'unknown error' };
  if (typeof err !== 'object') return { message: String(err) };
  const name = typeof err.name === 'string' && MEANINGFUL_ERROR_NAMES.has(err.name) ? err.name : undefined;
  const code = typeof err.code === 'string' && err.code.trim() ? err.code.trim() : undefined;
  const message = typeof err.message === 'string' && err.message.trim()
    ? err.message.trim()
    : (typeof err.reason === 'string' && err.reason.trim() ? err.reason.trim() : '');
  const topFrame = extractTopStackFrame(err.stack);
  return {
    ...(name ? { name } : {}),
    ...(code ? { code } : {}),
    message: message || name || code || 'unknown error',
    ...(topFrame ? { topFrame } : {}),
  };
}

/**
 * Log a non-fatal fallback / suppressed operational error with explicit scope & context.
 */
export function logSuppressed(logger, scope, err, { level = 'warn', detail = '' } = {}) {
  if (!logger) return;
  const fn = level === 'debug'
    ? (typeof logger.debug === 'function' ? logger.debug.bind(logger) : null)
    : (typeof logger.warn === 'function' ? logger.warn.bind(logger) : null);
  if (!fn) return;
  const info = describeError(err);
  const parts = [];
  if (detail) parts.push(detail);
  if (info.code) parts.push(`code=${info.code}`);
  if (info.name && !info.message.includes(info.name)) parts.push(info.name);
  parts.push(info.message);
  if (info.topFrame && level !== 'debug') parts.push(`at ${info.topFrame}`);
  fn(`[gbridge:${scope}] ${parts.join(' · ')}`);
}

/**
 * Explicit marker for best-effort resource teardown (e.g. `unlinkSync`, `socket.destroy`,
 * `server.close`, `ws.close`, `dispose`) where failures are genuinely harmless during shutdown.
 */
export function ignoreCleanupError(_err) {
  // Intentionally ignored: best-effort cleanup during teardown or already-closed handle.
}
