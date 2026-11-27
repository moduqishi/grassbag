/**
 * End-to-end DSH protocol round-trip & contract verification suite.
 *
 * Verifies the exact seams between `dsh-gbridge` and `@deepseek-ai/dsh` 0.2.x:
 *   1. `phone_screenshot` execute -> `attachments.saveImage()` -> `output.render()`
 *      -> content-block contract validation -> DSH `dsh-llm-pi-ai` & `dsh-llm-deepseek`
 *      request-builder round-trip (plus real `@deepseek-ai/dsh-attachment-local` when installed).
 *   2. Fail-closed rejection of provider-wire `{ type: 'image', data, mimeType }` blocks
 *      with structured warning logging (tool name + block shape).
 *   3. Poisoned multi-frame Zstandard session (`session-7ee83566` shape) -> in-place
 *      `repairLegacyInlineImageSessions()` -> multi-frame Zstd read -> LLM request builder.
 *   4. `[UNKNOWN]` error enrichment round-trip across `SessionNormalizer` and live `StreamHub`
 *      (surfacing tool name, malformed block shape, and top stack frame instead of bare `[UNKNOWN]`).
 *   5. Upstream DSH `presentation` metadata precedence & zero naked `catch {}` regression guard.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { constants as zlibConstants, zstdCompressSync } from 'node:zlib';
import { mountPhoneTools, renderPhoneToolOutput } from '../lib/phone-tools.js';
import {
  describeContentBlockShape,
  findMalformedContentBlocks,
  sanitizeToolContentBlocks,
  validateToolContentBlock,
} from '../lib/content-contract.js';
import {
  decodeConcatenatedZstd,
  repairLegacyInlineImageSessions,
} from '../lib/session-image-repair.js';
import { extractFailureInfo, SessionNormalizer, summarizeTool } from '../lib/normalizer.js';
import { StreamHub } from '../lib/stream-hub.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB_DIR = resolve(HERE, '../lib');

// Valid 1x1 RGB PNG (so even real libvips/Sharp raster decoders accept it cleanly!).
const TINY_VALID_PNG_B64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

const ZSTD_CHECKSUM_OPTIONS =
  zlibConstants && typeof zlibConstants.ZSTD_c_checksumFlag === 'number'
    ? { params: { [zlibConstants.ZSTD_c_checksumFlag]: 1 } }
    : undefined;

/**
 * Exact DSH 0.2.2-rc.5 `dsh-llm-pi-ai` + `dsh-llm-deepseek` request-builder contract harness:
 * mirrors `collectImageRefs` (`dsh-llm-pi-ai/lib/index.js:1264`),
 * `prepareRequestImages` (`:1269`), `userContent` (`:1237`), and `dsh-llm-deepseek` `serialize` (`:1656`).
 */
async function buildDshLlmRequestsFromMessages(messages, attachments) {
  const refs = new Map();
  for (const message of messages) {
    for (const block of message.content) {
      if (block.type === 'image' && block.offloaded !== true) {
        // Exact line that crashed in DSH 0.2.2-rc.5 when `block.attachment` was missing:
        refs.set(block.attachment.attachmentId, block.attachment);
      }
    }
  }
  const orderedRefs = [...refs.values()];
  const prepared = await Promise.all(
    orderedRefs.map((ref) => attachments.readImageRequest(ref, { maxWidth: 1024, maxHeight: 1024, maxBytes: 1048576 })),
  );
  const requestImages = new Map();
  for (const [idx, ref] of orderedRefs.entries()) {
    requestImages.set(ref.attachmentId, prepared[idx]);
  }

  // 1) pi-ai wire format projection
  const piMessages = messages.map((msg) => ({
    role: msg.role,
    content: msg.content.flatMap((block) => {
      if (block.type === 'text') return block.text.length > 0 ? [{ type: 'text', text: block.text }] : [];
      if (block.type === 'image') {
        const version = requestImages.get(block.attachment.attachmentId);
        assert.ok(version, `pi-ai missing prepared version for ${block.attachment.attachmentId}`);
        return [
          { type: 'text', text: `[image ${block.attachment.attachmentId}]` },
          { type: 'image', data: Buffer.from(version.data).toString('base64'), mimeType: version.mediaType },
        ];
      }
      return [];
    }),
  }));

  // 2) DeepSeek Messages wire format projection
  const deepseekMessages = messages.map((msg) => ({
    role: msg.role,
    content: msg.content.flatMap((block) => {
      if (block.type === 'text') return block.text ? [{ type: 'text', text: block.text }] : [];
      if (block.type === 'image') {
        const version = requestImages.get(block.attachment.attachmentId);
        assert.ok(version, `deepseek missing prepared version for ${block.attachment.attachmentId}`);
        return [
          { type: 'text', text: `[image ${block.attachment.attachmentId}]` },
          {
            type: 'image',
            source: {
              type: 'base64',
              media_type: version.mediaType,
              data: Buffer.from(version.data).toString('base64'),
            },
          },
        ];
      }
      return [];
    }),
  }));

  return { refs, piMessages, deepseekMessages };
}

function createInMemoryAttachmentStore() {
  const store = new Map();
  let seq = 0;
  return {
    async saveImage({ data, mediaType, name }) {
      const buf = Buffer.from(data);
      const attachmentId = `att_${++seq}_test`;
      const ref = {
        attachmentId,
        mediaType: mediaType || 'image/png',
        bytes: buf.byteLength,
        width: 1,
        height: 1,
        ...(name ? { name } : {}),
      };
      store.set(attachmentId, { ref, data: buf });
      return ref;
    },
    async readImageRequest(ref) {
      const hit = store.get(ref.attachmentId);
      if (!hit) throw new Error(`missing attachment ${ref.attachmentId}`);
      return {
        data: hit.data,
        mediaType: hit.ref.mediaType,
        bytes: hit.data.byteLength,
        width: hit.ref.width,
        height: hit.ref.height,
      };
    },
    store,
  };
}

function findInstalledLocalAttachmentModule() {
  const candidates = [
    resolve(HERE, '../../node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'),
    resolve(HERE, '../node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'),
    resolve(HERE, '../../../runtime/.staging/dsh-real/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'),
    '/opt/dsh-slots/current/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js',
  ];
  return candidates.find((p) => existsSync(p)) ?? null;
}

test('E2E round-trip: phone_screenshot -> saveImage -> render -> DSH pi-ai & deepseek request builders', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-rt-phone-'));
  const socketPath = join(dir, 'phone.sock');
  const token = 'rt-secret-token';
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      assert.equal(req.headers.authorization, `Bearer ${token}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(
        JSON.stringify({
          ok: true,
          mimeType: 'image/png',
          width: 1,
          height: 1,
          base64: TINY_VALID_PNG_B64,
        }),
      );
    });
  });
  await new Promise((r) => server.listen(socketPath, r));
  t.after(() => {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  });

  const attachments = createInMemoryAttachmentStore();
  const registeredTools = new Map();
  const warnings = [];
  const logger = { info() {}, debug() {}, warn: (...args) => warnings.push(args.join(' ')) };
  const ctx = {
    get(svc) {
      if (svc === 'tools') return { register: (def) => { registeredTools.set(def.name, def); return () => {}; } };
      if (svc === 'attachments') return attachments;
      return undefined;
    },
  };

  const mounted = mountPhoneTools(ctx, { socketPath, token, logger });
  t.after(() => mounted.dispose());

  const shotTool = registeredTools.get('phone_screenshot');
  assert.ok(shotTool, 'phone_screenshot must be registered');

  const execVal = await shotTool.execute({ maxWidth: 720, quality: 70 }, { callId: 'c1', session: { id: 'sess-rt-1' } });
  const contentBlocks = shotTool.output.render({}, execVal);

  assert.equal(warnings.length, 0, `unexpected contract warnings: ${warnings.join('; ')}`);
  assert.equal(contentBlocks.length, 2);
  assert.equal(contentBlocks[0].type, 'text');
  assert.equal(contentBlocks[1].type, 'image');
  assert.equal(contentBlocks[1].data, undefined, 'durable DSH image block must never have inline data');
  assert.equal(contentBlocks[1].mimeType, undefined, 'durable DSH image block must never have top-level mimeType');
  assert.ok(contentBlocks[1].attachment?.attachmentId, 'durable DSH image block must carry attachment.attachmentId');

  // Verify EVERY emitted block passes the strict DSH contract validator
  for (const block of contentBlocks) {
    assert.equal(validateToolContentBlock(block).ok, true);
  }

  // Round-trip through DSH LLM request builders (both pi-ai and DeepSeek Messages wire projections)
  const messages = [{ role: 'tool', toolCallId: 'c1', content: contentBlocks }];
  const built = await buildDshLlmRequestsFromMessages(messages, attachments);
  assert.equal(built.refs.size, 1);
  assert.equal(built.piMessages[0].content.at(-1).type, 'image');
  assert.equal(built.piMessages[0].content.at(-1).data, TINY_VALID_PNG_B64);
  assert.equal(built.deepseekMessages[0].content.at(-1).source.type, 'base64');
  assert.equal(built.deepseekMessages[0].content.at(-1).source.data, TINY_VALID_PNG_B64);

  // Bonus: when real `@deepseek-ai/dsh-attachment-local` is present on disk, verify real
  // `prepareImageFile` -> `commitPreparedImageFile` -> `readImageFile` -> `renderPhoneToolOutput`!
  const localAttPath = findInstalledLocalAttachmentModule();
  if (localAttPath) {
    const mod = await import(pathToFileURL(localAttPath).href);
    if (typeof mod.prepareImageFile === 'function' && typeof mod.commitPreparedImageFile === 'function') {
      const realStoreDir = join(dir, 'dsh-home', 'attachments', 'v1');
      const limits = {
        maxImageBytes: mod.DEFAULT_MAX_IMAGE_BYTES ?? 52428800,
        maxImagesPerMessage: mod.DEFAULT_MAX_IMAGES_PER_MESSAGE ?? 20,
        maxMessageImageBytes: mod.DEFAULT_MAX_MESSAGE_IMAGE_BYTES ?? 209715200,
        maxImagePixels: mod.DEFAULT_MAX_IMAGE_PIXELS ?? 64e6,
        maxImageDimension: mod.DEFAULT_MAX_IMAGE_DIMENSION ?? 65535,
        mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
      };
      const normPolicy = {
        maxPixels: mod.DEFAULT_NORMALIZED_IMAGE_MAX_PIXELS ?? 4194304,
        maxDimension: mod.DEFAULT_NORMALIZED_IMAGE_MAX_DIMENSION ?? 8192,
        maxBytes: mod.DEFAULT_NORMALIZED_IMAGE_MAX_BYTES ?? 4194304,
      };
      const prepared = await mod.prepareImageFile(
        { data: Buffer.from(TINY_VALID_PNG_B64, 'base64'), mediaType: 'image/png', name: 'roundtrip.png' },
        limits,
        normPolicy,
      );
      const saved = await mod.commitPreparedImageFile(realStoreDir, prepared);
      const realBlocks = renderPhoneToolOutput('phone_screenshot', { ok: true, image: saved }, { logger });
      assert.equal(realBlocks[1].type, 'image');
      assert.equal(realBlocks[1].attachment.attachmentId, saved.attachmentId);
      assert.equal(validateToolContentBlock(realBlocks[1]).ok, true);
      if (typeof mod.readImageFile === 'function') {
        const stored = await mod.readImageFile(realStoreDir, realBlocks[1].attachment);
        assert.ok(stored.data.byteLength > 0);
      }
    }
  }
});

test('contract validator blocks legacy inline provider image block fail-closed and logs tool + shape', () => {
  const warnings = [];
  const violations = [];
  const logger = { warn: (msg) => warnings.push(msg) };

  const badInline = { type: 'image', data: TINY_VALID_PNG_B64, mimeType: 'image/jpeg' };
  const badMissingId = { type: 'image', attachment: { mediaType: 'image/png', width: 10, height: 10, bytes: 123 } };
  const badUnknown = { type: 'widget_blob', payload: 42 };

  const check = validateToolContentBlock(badInline);
  assert.equal(check.ok, false);
  assert.equal(check.reason, 'inline_provider_image_block_forbidden');
  assert.deepEqual(describeContentBlockShape(badInline), {
    type: 'image',
    keys: ['type', 'data', 'mimeType'],
  });

  const safe = sanitizeToolContentBlocks('phone_screenshot', [badInline, badMissingId, badUnknown], {
    logger,
    onViolation: (v) => violations.push(v),
  });

  assert.equal(safe.length, 3);
  for (const b of safe) {
    assert.equal(b.type, 'text', 'every invalid block must degrade to safe diagnostic text');
    assert.equal(validateToolContentBlock(b).ok, true);
    const parsed = JSON.parse(b.text);
    assert.equal(parsed._gbridgeContractBlocked, true);
    assert.equal(parsed.tool, 'phone_screenshot');
  }
  assert.equal(violations.length, 3);
  assert.equal(violations[0].reason, 'inline_provider_image_block_forbidden');
  assert.equal(violations[1].reason, 'missing_attachment_id');
  assert.equal(violations[2].reason, 'unsupported_content_block_type');
  assert.ok(warnings[0].includes('phone_screenshot'));
  assert.ok(warnings[0].includes('"type":"image"'));
  assert.ok(warnings[0].includes('"mimeType"'));

  // Even malformed `attachment` passed into `renderPhoneToolOutput` cannot bypass the validator
  const rendered = renderPhoneToolOutput(
    'phone_screenshot',
    { ok: true, attachment: { mediaType: 'image/jpeg' } },
    { logger },
  );
  assert.ok(rendered.every((b) => b.type === 'text'));
});

test('E2E poisoned session-7ee83566 multi-frame Zstd -> repair -> DSH request builder succeeds', async (t) => {
  const dshHome = mkdtempSync(join(tmpdir(), 'gbridge-rt-zstd-'));
  t.after(() => rmSync(dshHome, { recursive: true, force: true }));

  const sessDir = join(dshHome, 'sessions', '--root-workspace--', 'session-7ee83566-872f-4ca3-9e54-9d166ece8d4c');
  mkdirSync(sessDir, { recursive: true });
  const logPath = join(sessDir, 'session.v4.jsonl.zstd');

  const frame0 = `${JSON.stringify({
    seq: 1,
    type: 'user/message',
    data: { message: { role: 'user', content: [{ type: 'text', text: '帮我截个屏看看' }] } },
  })}\n`;
  const poisonedToolEvent = {
    seq: 2,
    type: 'tool/result',
    data: {
      name: 'phone_screenshot',
      message: {
        role: 'tool',
        toolCallId: 'call-shot-1',
        content: [
          { type: 'text', text: '{"ok":true,"width":1,"height":1}' },
          { type: 'image', data: TINY_VALID_PNG_B64, mimeType: 'image/png' },
        ],
      },
    },
  };
  const frame1 = `${JSON.stringify(poisonedToolEvent)}\n`;
  const frame2 = `${JSON.stringify({
    seq: 3,
    type: 'assistant/message',
    data: { message: { role: 'assistant', content: [{ type: 'text', text: '已截屏' }] } },
  })}\n`;

  writeFileSync(
    logPath,
    Buffer.concat([
      zstdCompressSync(Buffer.from(frame0, 'utf8'), ZSTD_CHECKSUM_OPTIONS),
      zstdCompressSync(Buffer.from(frame1, 'utf8'), ZSTD_CHECKSUM_OPTIONS),
      zstdCompressSync(Buffer.from(frame2, 'utf8'), ZSTD_CHECKSUM_OPTIONS),
    ]),
  );

  const attachments = createInMemoryAttachmentStore();

  // Prove BEFORE repair: exact DSH crash happens on poisoned tool result
  const beforeLines = decodeConcatenatedZstd(readFileSync(logPath)).trim().split('\n').map((l) => JSON.parse(l));
  const beforeMsgs = beforeLines.map((e) => e.data.message);
  await assert.rejects(
    () => buildDshLlmRequestsFromMessages(beforeMsgs, attachments),
    /attachmentId/,
    'poisoned session must reproduce DSH TypeError before repair',
  );

  // Run startup auto-healer
  const summary = await repairLegacyInlineImageSessions({ dshHome, attachments });
  assert.equal(summary.filesRepaired, 1);
  assert.equal(summary.repairedBlocks, 1);
  assert.equal(summary.fallbackBlocks, 0);

  // Prove AFTER repair: all 3 frames intact and DSH request builders succeed cleanly!
  const afterLines = decodeConcatenatedZstd(readFileSync(logPath)).trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(afterLines.length, 3);
  const repairedToolContent = afterLines[1].data.message.content;
  assert.equal(findMalformedContentBlocks(repairedToolContent).length, 0);
  const built = await buildDshLlmRequestsFromMessages(afterLines.map((e) => e.data.message), attachments);
  assert.equal(built.refs.size, 1);
  assert.equal(built.piMessages[1].content.at(-1).data, TINY_VALID_PNG_B64);
});

test('UNKNOWN error enrichment round-trip attaches concrete tool name, block shape, and stack location', () => {
  const normalizer = new SessionNormalizer();
  const poisonedEvents = [
    { seq: 1, type: 'turn/start', data: { turnId: 'turn-4' } },
    { seq: 2, type: 'tool/call', data: { callId: 'c-shot', name: 'phone_screenshot', arguments: '{}' } },
    {
      seq: 3,
      type: 'tool/result',
      data: {
        callId: 'c-shot',
        name: 'phone_screenshot',
        message: {
          role: 'tool',
          toolCallId: 'c-shot',
          content: [
            { type: 'text', text: '{"ok":true}' },
            { type: 'image', data: TINY_VALID_PNG_B64, mimeType: 'image/jpeg' },
          ],
        },
      },
    },
    {
      seq: 4,
      type: 'turn/end',
      data: {
        turnId: 'turn-4',
        reason: {
          kind: 'error',
          error: {
            code: 'UNKNOWN',
            name: 'TypeError',
            message: "Cannot read properties of undefined (reading 'attachmentId')",
            stack:
              "TypeError: Cannot read properties of undefined (reading 'attachmentId')\n" +
              '    at collectImageRefs (/opt/dsh-slots/current/node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js:1266:45)',
          },
        },
      },
    },
  ];

  // 1) History page normalization path
  const turns = normalizer.normalizeEvents('sess-err-1', poisonedEvents);
  assert.equal(turns.length, 1);
  assert.equal(turns[0].status, 'error');
  assert.equal(turns[0].errorCode, 'UNKNOWN');
  assert.match(turns[0].errorMessage, /phone_screenshot/);
  assert.match(turns[0].errorMessage, /\{type:"image", keys:\[type,data,mimeType\]\}/);
  assert.match(turns[0].errorMessage, /缺少 attachment\.attachmentId/);
  assert.match(turns[0].errorMessage, /dsh-llm-pi-ai\/lib\/index\.js:1266/);

  // 2) Live incremental StreamHub path
  const liveNormalizer = new SessionNormalizer();
  const published = [];
  const hub = new StreamHub({
    bootId: 'boot-err-test',
    gateway: { has: () => false },
    normalizer: liveNormalizer,
  });
  const origPublish = hub.publish.bind(hub);
  hub.publish = (channel, type, data) => {
    published.push({ channel, type, data });
    return origPublish(channel, type, data);
  };
  for (const ev of poisonedEvents) {
    hub._forwardUpstreamStreamItem('session', 'sess-live-err', 'session:sess-live-err', { type: 'event', event: ev });
  }
  hub.dispose();
  const completed = published.find((f) => f.type === 'turn.completed');
  assert.ok(completed, 'StreamHub must publish turn.completed');
  assert.equal(completed.data.errorCode, 'UNKNOWN');
  assert.match(completed.data.errorMessage, /phone_screenshot/);
  assert.match(completed.data.errorMessage, /\{type:"image", keys:\[type,data,mimeType\]\}/);

  // 3) Direct `extractFailureInfo` with structured details
  const direct = extractFailureInfo('error', {
    error: {
      code: 'UNKNOWN',
      message: 'request failed',
      details: { toolName: 'phone_screenshot', endpoint: 'session/prompt', blockType: 'image', blockKeys: ['type', 'data', 'mimeType'] },
    },
  });
  assert.match(direct.message, /工具: phone_screenshot/);
  assert.match(direct.message, /块形状: \{type:"image", keys:\[type,data,mimeType\]\}/);
  assert.match(direct.message, /接口: session\/prompt/);
});

test('summarizeTool prefers upstream DSH presentation metadata over shadow heuristics', () => {
  const fromUpstream = summarizeTool(
    'read',
    { file_path: '/root/workspace/a.js' },
    'raw file text',
    undefined,
    { title: 'Read src/a.js', summary: '42 lines · JavaScript' },
  );
  assert.equal(fromUpstream.title, 'Read src/a.js');
  assert.equal(fromUpstream.summary, '42 lines · JavaScript');

  const normalizer = new SessionNormalizer();
  const turns = normalizer.normalizeEvents('sess-pres-1', [
    {
      seq: 1,
      type: 'tool/call',
      data: {
        callId: 'c-pres',
        name: 'custom_dsh_tool',
        arguments: { target: 'ignored' },
        presentation: { title: 'Custom Upstream Title', summary: 'Running upstream…' },
      },
    },
    {
      seq: 2,
      type: 'tool/result',
      data: {
        callId: 'c-pres',
        name: 'custom_dsh_tool',
        output: 'done',
        presentation: { title: 'Custom Upstream Title', summary: 'Upstream Summary Ready' },
      },
    },
  ]);
  assert.equal(turns[0].steps[0].title, 'Custom Upstream Title');
  assert.equal(turns[0].steps[0].summary, 'Upstream Summary Ready');
});

test('regression guard: zero silent empty catch {} blocks in dsh-gbridge/lib', () => {
  const offenders = [];
  const walk = (dir) => {
    for (const ent of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, ent.name);
      if (ent.isDirectory()) walk(full);
      else if (ent.isFile() && ent.name.endsWith('.js')) {
        const lines = readFileSync(full, 'utf8').split('\n');
        lines.forEach((line, idx) => {
          const trimmed = line.trim();
          if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) return;
          if (/catch\s*\{\s*\}/.test(line)) {
            offenders.push(`${full}:${idx + 1}: ${trimmed}`);
          }
        });
      }
    }
  };
  walk(LIB_DIR);
  assert.deepEqual(offenders, [], `Found silent empty catch {} blocks:\n${offenders.join('\n')}`);
});
