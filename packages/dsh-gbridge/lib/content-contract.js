/**
 * Strict DSH 0.2.x durable tool content-block contract validator & fail-closed admission guard.
 *
 * DSH's durable session format & LLM request builders (`@deepseek-ai/dsh-llm-pi-ai` and
 * `@deepseek-ai/dsh-llm-deepseek`) require EVERY persisted tool-result content block to match
 * the canonical DSH block schema:
 *   - `{ type: 'text', text: string }`
 *   - `{ type: 'image', attachment: { attachmentId, mediaType, bytes, width, height, ... } }`
 *   - `{ type: 'file', attachment: { attachmentId, name, bytes, ... } }`
 *
 * Provider-wire inline images (`{ type: 'image', data, mimeType }`) MUST NEVER enter a DSH
 * session log — doing so causes `dsh-llm-pi-ai` (`refs.set(block.attachment.attachmentId, ...)`)
 * and `dsh-llm-deepseek` to crash with an opaque `[UNKNOWN]` TypeError on every future turn!
 */

const VALID_IMAGE_MEDIA_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
]);

const FORBIDDEN_INLINE_IMAGE_KEYS = ['data', 'base64', 'mimeType', 'source', 'image'];

function isPositiveSafeInt(v) {
  return typeof v === 'number' && Number.isInteger(v) && Number.isSafeInteger(v) && v > 0;
}

function isNonNegativeFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0;
}

/**
 * Safe structural summary of a content block (never leaks raw base64 payloads).
 */
export function describeContentBlockShape(block) {
  if (block === null) return { type: 'null', keys: [] };
  if (typeof block !== 'object' || Array.isArray(block)) {
    return { type: Array.isArray(block) ? 'array' : typeof block, keys: [] };
  }
  const keys = Object.keys(block);
  const type = typeof block.type === 'string' && block.type ? block.type : '(missing)';
  const out = { type, keys };
  if (block.attachment && typeof block.attachment === 'object' && !Array.isArray(block.attachment)) {
    out.attachmentKeys = Object.keys(block.attachment);
  }
  return out;
}

/**
 * Inspect an array of content blocks (e.g. from `tool/result`) and return diagnostics for any
 * malformed blocks (especially legacy/third-party inline `{ type: 'image', data, mimeType }`).
 */
export function findMalformedContentBlocks(blocks) {
  if (!Array.isArray(blocks) || blocks.length === 0) return [];
  const findings = [];
  for (let i = 0; i < blocks.length; i++) {
    const res = validateToolContentBlock(blocks[i]);
    if (!res.ok) {
      findings.push({
        index: i,
        reason: res.reason,
        detail: res.detail,
        shape: res.shape,
      });
    }
  }
  return findings;
}

/**
 * Validate a single tool-result content block against DSH's durable content-block contract.
 * Returns `{ ok: true, normalized }` or `{ ok: false, reason, detail, shape }`.
 */
export function validateToolContentBlock(block) {
  const shape = describeContentBlockShape(block);
  if (!block || typeof block !== 'object' || Array.isArray(block)) {
    return {
      ok: false,
      reason: 'invalid_block_container',
      detail: `content block must be a plain object, got ${shape.type}`,
      shape,
    };
  }
  if (typeof block.type !== 'string' || !block.type.trim()) {
    return {
      ok: false,
      reason: 'missing_block_type',
      detail: `content block is missing string "type" (keys=[${shape.keys.join(',')}])`,
      shape,
    };
  }

  if (block.type === 'text') {
    if (typeof block.text !== 'string') {
      return {
        ok: false,
        reason: 'invalid_text_block',
        detail: `text block requires string "text", got ${typeof block.text}`,
        shape,
      };
    }
    return { ok: true, normalized: { type: 'text', text: block.text } };
  }

  if (block.type === 'image') {
    const forbidden = FORBIDDEN_INLINE_IMAGE_KEYS.filter((k) => block[k] !== undefined);
    const att = block.attachment;
    if (!att || typeof att !== 'object' || Array.isArray(att)) {
      const hasInline = forbidden.length > 0;
      return {
        ok: false,
        reason: hasInline ? 'inline_provider_image_block_forbidden' : 'missing_image_attachment',
        detail: hasInline
          ? `image block used provider-wire inline keys [${forbidden.join(',')}] without durable attachment.attachmentId`
          : `image block is missing durable "attachment" object (keys=[${shape.keys.join(',')}])`,
        shape,
      };
    }
    if (forbidden.length > 0) {
      return {
        ok: false,
        reason: 'inline_provider_image_block_forbidden',
        detail: `image block carries forbidden top-level inline keys [${forbidden.join(',')}] alongside attachment`,
        shape,
      };
    }
    if (typeof att.attachmentId !== 'string' || !att.attachmentId.trim()) {
      return {
        ok: false,
        reason: 'missing_attachment_id',
        detail: `image attachment is missing non-empty string "attachmentId" (attachmentKeys=[${(shape.attachmentKeys || []).join(',')}])`,
        shape,
      };
    }
    if (typeof att.mediaType !== 'string' || !VALID_IMAGE_MEDIA_TYPES.has(att.mediaType)) {
      return {
        ok: false,
        reason: 'invalid_image_media_type',
        detail: `image attachment mediaType must be one of jpeg/png/webp/gif, got ${JSON.stringify(att.mediaType)}`,
        shape,
      };
    }
    if (!isPositiveSafeInt(att.bytes)) {
      return {
        ok: false,
        reason: 'invalid_image_bytes',
        detail: `image attachment requires positive integer "bytes", got ${JSON.stringify(att.bytes)}`,
        shape,
      };
    }
    if (!isPositiveSafeInt(att.width) || !isPositiveSafeInt(att.height)) {
      return {
        ok: false,
        reason: 'invalid_image_dimensions',
        detail: `image attachment requires positive integer width/height, got ${JSON.stringify(att.width)}x${JSON.stringify(att.height)}`,
        shape,
      };
    }
    const normalizedAttachment = {
      attachmentId: att.attachmentId,
      mediaType: att.mediaType,
      bytes: att.bytes,
      width: att.width,
      height: att.height,
    };
    if (att.name !== undefined) {
      if (typeof att.name !== 'string') {
        return {
          ok: false,
          reason: 'invalid_image_name',
          detail: `image attachment "name" must be a string when present`,
          shape,
        };
      }
      normalizedAttachment.name = att.name;
    }
    if (att.originalDimensions !== undefined) {
      const od = att.originalDimensions;
      if (!od || typeof od !== 'object' || !isPositiveSafeInt(od.width) || !isPositiveSafeInt(od.height)) {
        return {
          ok: false,
          reason: 'invalid_original_dimensions',
          detail: `image attachment "originalDimensions" must have positive integer width and height`,
          shape,
        };
      }
      normalizedAttachment.originalDimensions = { width: od.width, height: od.height };
    }
    const normalized = { type: 'image', attachment: normalizedAttachment };
    if (block.offloaded === true) normalized.offloaded = true;
    return { ok: true, normalized };
  }

  if (block.type === 'file') {
    const att = block.attachment;
    if (!att || typeof att !== 'object' || Array.isArray(att) || typeof att.attachmentId !== 'string' || !att.attachmentId.trim()) {
      return {
        ok: false,
        reason: 'missing_file_attachment',
        detail: `file block requires durable attachment.attachmentId (keys=[${shape.keys.join(',')}])`,
        shape,
      };
    }
    if (typeof att.name !== 'string' || !isNonNegativeFiniteNumber(att.bytes)) {
      return {
        ok: false,
        reason: 'invalid_file_attachment',
        detail: `file attachment requires string "name" and numeric "bytes"`,
        shape,
      };
    }
    return {
      ok: true,
      normalized: {
        type: 'file',
        attachment: {
          attachmentId: att.attachmentId,
          name: att.name,
          bytes: att.bytes,
          ...(typeof att.mediaType === 'string' ? { mediaType: att.mediaType } : {}),
        },
      },
    };
  }

  return {
    ok: false,
    reason: 'unsupported_content_block_type',
    detail: `unsupported DSH tool content block type "${block.type}" (keys=[${shape.keys.join(',')}])`,
    shape,
  };
}

/**
 * Validate and fail-closed sanitize an entire tool output content-block array before returning
 * it to DSH. Invalid blocks are logged with concrete tool name + block shape and safely
 * downgraded to diagnostic text blocks so they can NEVER poison `session.v4.jsonl.zstd`.
 */
export function sanitizeToolContentBlocks(toolName, rawBlocks, { logger, onViolation } = {}) {
  const safeTool = String(toolName || 'unknown_tool');
  const list = Array.isArray(rawBlocks) ? rawBlocks : (rawBlocks == null ? [] : [rawBlocks]);
  const sanitized = [];

  for (let i = 0; i < list.length; i++) {
    const block = list[i];
    const res = validateToolContentBlock(block);
    if (res.ok) {
      sanitized.push(res.normalized);
      continue;
    }
    const violation = {
      toolName: safeTool,
      index: i,
      reason: res.reason,
      detail: res.detail,
      shape: res.shape,
    };
    logger?.warn?.(
      `[gbridge:content-contract] blocked invalid content block from tool="${safeTool}" index=${i} reason=${res.reason} shape=${JSON.stringify(res.shape)}: ${res.detail}`,
    );
    try {
      onViolation?.(violation);
    } catch (err) {
      logger?.warn?.(`[gbridge:content-contract] onViolation hook failed: ${err?.message || err}`);
    }
    sanitized.push({
      type: 'text',
      text: JSON.stringify({
        _gbridgeContractBlocked: true,
        tool: safeTool,
        blockType: res.shape.type,
        blockKeys: res.shape.keys,
        reason: res.reason,
        detail: res.detail,
      }),
    });
  }

  if (sanitized.length === 0) {
    sanitized.push({ type: 'text', text: '{}' });
  }
  return sanitized;
}
