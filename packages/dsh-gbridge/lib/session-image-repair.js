import { existsSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as zlib from 'node:zlib';
import { ignoreCleanupError } from './diagnostics.js';

const zlibConstants = zlib.constants;
function requireZstdFn(name) {
  const fn = zlib[name];
  if (typeof fn !== 'function') {
    throw new Error(`Node.js >= 22.15.0 is required for built-in zlib.${name} (current: ${process.versions?.node ?? 'unknown'})`);
  }
  return fn;
}
const zstdCompressSync = (...args) => requireZstdFn('zstdCompressSync')(...args);
const zstdDecompressSync = (...args) => requireZstdFn('zstdDecompressSync')(...args);

const ZSTD_MAGIC = 0xFD2FB528;

const SUPPORTED_IMAGE_MEDIA_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
]);

const EXT_BY_MEDIA_TYPE = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
};

const ZSTD_CHECKSUM_OPTIONS = (zlibConstants && typeof zlibConstants.ZSTD_c_checksumFlag === 'number')
  ? { params: { [zlibConstants.ZSTD_c_checksumFlag]: 1 } }
  : undefined;

export function normalizeImageMediaType(raw) {
  const cleaned = String(raw || '').trim().toLowerCase().split(';')[0].trim();
  if (cleaned === 'image/jpg') return 'image/jpeg';
  if (SUPPORTED_IMAGE_MEDIA_TYPES.has(cleaned)) return cleaned;
  return 'image/jpeg';
}

export function imageExtensionForMediaType(mediaType) {
  return EXT_BY_MEDIA_TYPE[normalizeImageMediaType(mediaType)] || 'jpg';
}

export function toCanonicalImageAttachmentRef(ref) {
  if (!ref || typeof ref !== 'object' || typeof ref.attachmentId !== 'string' || !ref.attachmentId) {
    return null;
  }
  const out = {
    attachmentId: ref.attachmentId,
    mediaType: ref.mediaType,
    bytes: ref.bytes,
    width: ref.width,
    height: ref.height,
  };
  if (ref.name !== undefined) out.name = ref.name;
  if (ref.originalDimensions !== undefined && ref.originalDimensions !== null) {
    out.originalDimensions = {
      width: ref.originalDimensions.width,
      height: ref.originalDimensions.height,
    };
  }
  return out;
}

/**
 * RFC 8878 structural scanner for DSH's concatenated multi-frame Zstandard session logs
 * (Node's one-shot `zstdDecompressSync` stops after frame 0!).
 */
export function scanZstdFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) return { frames, tornStart: start };
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error(`invalid zstd frame magic at byte ${offset}`);
    }
    offset += 4;
    if (offset === buffer.length) return { frames, tornStart: start };
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 0x18) !== 0) {
      throw new Error(`reserved zstd frame header bit at byte ${offset - 1}`);
    }
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 0x20) !== 0;
    const checksum = (descriptor & 0x04) !== 0;
    const dictionaryFlag = descriptor & 0x03;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0
      ? (singleSegment ? 1 : 0)
      : (1 << contentSizeFlag);
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start };
    offset += remainingHeaderBytes;

    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start };
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 0x03;
      const blockSize = blockHeader >>> 3;
      if (blockType === 0x03) {
        throw new Error(`reserved zstd block type at byte ${offset - 3}`);
      }
      const payloadBytes = blockType === 0x01 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) return { frames, tornStart: start };
      offset += payloadBytes;
      if (lastBlock) break;
    }

    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start };
      offset += 4;
    }
    frames.push({ start, end: offset });
  }
  return { frames, tornStart: undefined };
}

export function decodeConcatenatedZstd(buffer) {
  const { frames } = scanZstdFrames(buffer);
  const parts = [];
  for (const frame of frames) {
    parts.push(zstdDecompressSync(buffer.subarray(frame.start, frame.end)));
  }
  return Buffer.concat(parts).toString('utf8');
}

function isLegacyInlineImageBlock(block) {
  if (!block || typeof block !== 'object') return false;
  if (block.type !== 'image') return false;
  return !(block.attachment && typeof block.attachment === 'object' && typeof block.attachment.attachmentId === 'string' && block.attachment.attachmentId.length > 0);
}

function collectContentArrays(record) {
  const arrays = [];
  if (!record || typeof record !== 'object') return arrays;
  if (Array.isArray(record.data?.message?.content)) arrays.push(record.data.message.content);
  if (Array.isArray(record.event?.data?.message?.content)) arrays.push(record.event.data.message.content);
  if (Array.isArray(record.message?.content)) arrays.push(record.message.content);
  if (Array.isArray(record.data?.content)) arrays.push(record.data.content);
  return arrays;
}

async function repairJsonlChunk(text, filePath, { attachments, logger }) {
  // Fast O(N) substring bailout: frames without image blocks skip JSON parsing completely.
  if (!text.includes('"type":"image"') && !text.includes('"type": "image"')) {
    return { changed: false, text, repairedBlocks: 0, fallbackBlocks: 0 };
  }
  const hasTrailingNewline = text.endsWith('\n');
  const lines = hasTrailingNewline ? text.slice(0, -1).split('\n') : text.split('\n');
  let repairedBlocks = 0;
  let fallbackBlocks = 0;
  let changed = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line || (!line.includes('"type":"image"') && !line.includes('"type": "image"'))) {
      continue;
    }
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const contentArrays = collectContentArrays(parsed);
    let lineMutated = false;
    for (const arr of contentArrays) {
      for (let j = 0; j < arr.length; j++) {
        const block = arr[j];
        if (!isLegacyInlineImageBlock(block)) continue;

        let migrated = null;
        if (
          attachments &&
          typeof attachments.saveImage === 'function' &&
          typeof block.data === 'string' &&
          block.data.trim().length > 0
        ) {
          try {
            const mediaType = normalizeImageMediaType(block.mimeType ?? block.mediaType);
            const buf = Buffer.from(block.data.trim(), 'base64');
            if (buf.length > 0) {
              const ext = imageExtensionForMediaType(mediaType);
              const ref = await attachments.saveImage({
                data: buf,
                mediaType,
                name: typeof block.name === 'string' && block.name.trim()
                  ? block.name.trim()
                  : `migrated-screenshot-${parsed?.seq ?? i}-${j}.${ext}`,
              });
              const canonical = toCanonicalImageAttachmentRef(ref);
              if (canonical) {
                migrated = { type: 'image', attachment: canonical };
              }
            }
          } catch (err) {
            logger?.warn?.(`[gbridge] failed to migrate inline image in ${filePath} seq=${parsed?.seq ?? i}:`, err?.message || err);
          }
        }

        if (migrated) {
          arr[j] = migrated;
          repairedBlocks++;
        } else {
          // Never leave a dangling `{ type: 'image' }` block without `attachment` — that crashes
          // `dsh-llm-pi-ai` and `dsh-llm-deepseek` on every subsequent resume of this session!
          arr[j] = {
            type: 'text',
            text: '[screenshot omitted: legacy inline image block migrated for compatibility]',
          };
          fallbackBlocks++;
        }
        lineMutated = true;
      }
    }
    if (lineMutated) {
      lines[i] = JSON.stringify(parsed);
      changed = true;
    }
  }

  if (!changed) {
    return { changed: false, text, repairedBlocks: 0, fallbackBlocks: 0 };
  }
  return {
    changed: true,
    text: `${lines.join('\n')}${hasTrailingNewline ? '\n' : ''}`,
    repairedBlocks,
    fallbackBlocks,
  };
}

/**
 * Repair a single DSH session file (`session.v4.jsonl.zstd` or `.jsonl`) in place,
 * migrating legacy `{ type: 'image', data, mimeType }` blocks into durable
 * `{ type: 'image', attachment: ImageAttachmentRef }` references via `attachments.saveImage()`.
 * Preserves multi-frame Zstandard boundaries and checksums bit-for-bit on unaffected frames.
 */
export async function repairSessionFile(filePath, { attachments, logger } = {}) {
  if (!filePath || !existsSync(filePath)) {
    return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
  }
  const isZstd = filePath.endsWith('.zstd');
  const rawBytes = readFileSync(filePath);
  if (rawBytes.length === 0) {
    return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
  }

  let outBytes;
  let repairedBlocks = 0;
  let fallbackBlocks = 0;
  let changed = false;

  if (isZstd) {
    let scan;
    try {
      scan = scanZstdFrames(rawBytes);
    } catch (err) {
      logger?.warn?.(`[gbridge] skipping unreadable zstd session file ${filePath}:`, err?.message || err);
      return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
    }
    const outputFrames = [];
    for (const frame of scan.frames) {
      const slice = rawBytes.subarray(frame.start, frame.end);
      let frameText;
      try {
        frameText = zstdDecompressSync(slice).toString('utf8');
      } catch (err) {
        logger?.warn?.(`[gbridge] skipping corrupt zstd frame in ${filePath}:`, err?.message || err);
        return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
      }
      const res = await repairJsonlChunk(frameText, filePath, { attachments, logger });
      if (res.changed) {
        const compressed = zstdCompressSync(Buffer.from(res.text, 'utf8'), ZSTD_CHECKSUM_OPTIONS);
        if (zstdDecompressSync(compressed).toString('utf8') !== res.text) {
          throw new Error(`zstd frame verification mismatch while repairing ${filePath}`);
        }
        outputFrames.push(compressed);
        repairedBlocks += res.repairedBlocks;
        fallbackBlocks += res.fallbackBlocks;
        changed = true;
      } else {
        outputFrames.push(slice);
      }
    }
    if (!changed) {
      return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
    }
    if (scan.tornStart !== undefined && scan.tornStart < rawBytes.length) {
      outputFrames.push(rawBytes.subarray(scan.tornStart));
    }
    outBytes = Buffer.concat(outputFrames);
  } else {
    const rawText = rawBytes.toString('utf8');
    const res = await repairJsonlChunk(rawText, filePath, { attachments, logger });
    if (!res.changed) {
      return { changed: false, repairedBlocks: 0, fallbackBlocks: 0 };
    }
    repairedBlocks = res.repairedBlocks;
    fallbackBlocks = res.fallbackBlocks;
    changed = true;
    outBytes = Buffer.from(res.text, 'utf8');
  }

  const tmpPath = `${filePath}.gbridge-repair.${process.pid}.tmp`;
  try {
    writeFileSync(tmpPath, outBytes);
    renameSync(tmpPath, filePath);
  } catch (err) {
    try { unlinkSync(tmpPath); } catch (cleanupErr) { ignoreCleanupError(cleanupErr); }
    throw err;
  }

  logger?.info?.(
    `[gbridge] repaired legacy inline image session ${filePath} (migrated=${repairedBlocks}, fallback=${fallbackBlocks})`,
  );
  return { changed: true, repairedBlocks, fallbackBlocks };
}

function collectSessionLogFiles(rootDir, maxDepth = 3) {
  const found = [];
  if (!rootDir || !existsSync(rootDir)) return found;
  const walk = (dir, depth) => {
    if (depth > maxDepth) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      const full = join(dir, ent.name);
      if (ent.isDirectory()) {
        walk(full, depth + 1);
      } else if (
        ent.isFile() &&
        (ent.name === 'session.v4.jsonl.zstd' ||
          ent.name === 'session.v4.jsonl' ||
          ent.name === 'session.jsonl')
      ) {
        found.push(full);
      }
    }
  };
  walk(rootDir, 0);
  return found;
}

/**
 * Idempotently scans `<dshHome>/sessions` and repairs any historical sessions containing
 * legacy inline `{ type: 'image', data, mimeType }` tool results (e.g. from older `phone_screenshot`).
 */
export async function repairLegacyInlineImageSessions({ dshHome, attachments, logger } = {}) {
  const sessionsRoot = dshHome ? join(dshHome, 'sessions') : '';
  const files = collectSessionLogFiles(sessionsRoot, 3);
  let filesRepaired = 0;
  let repairedBlocks = 0;
  let fallbackBlocks = 0;
  for (const filePath of files) {
    try {
      const res = await repairSessionFile(filePath, { attachments, logger });
      if (res.changed) {
        filesRepaired++;
        repairedBlocks += res.repairedBlocks;
        fallbackBlocks += res.fallbackBlocks;
      }
    } catch (err) {
      logger?.warn?.(`[gbridge] legacy image repair failed for ${filePath}:`, err?.message || err);
    }
  }
  return { scannedFiles: files.length, filesRepaired, repairedBlocks, fallbackBlocks };
}
