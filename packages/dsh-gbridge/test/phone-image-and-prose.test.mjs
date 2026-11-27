import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { constants as zlibConstants, zstdCompressSync, zstdDecompressSync } from 'node:zlib';
import { mountPhoneTools } from '../lib/phone-tools.js';
import { decodeConcatenatedZstd, repairLegacyInlineImageSessions, repairSessionFile, scanZstdFrames } from '../lib/session-image-repair.js';
import { SessionNormalizer } from '../lib/normalizer.js';

const TINY_JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0xff, 0xd9]).toString('base64');

test('phone_screenshot saves image via ctx.attachments.saveImage and emits canonical attachment block', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-phone-img-'));
  const socketPath = join(dir, 'phone.sock');
  const token = 'test-secret-token';
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        width: 720,
        height: 1600,
        mimeType: 'image/jpeg',
        base64: TINY_JPEG_B64,
      }));
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));

  try {
    const registeredTools = new Map();
    const savedCalls = [];
    const attachments = {
      async saveImage(input) {
        savedCalls.push(input);
        return {
          attachmentId: 'att_phone_shot_001',
          mediaType: input.mediaType,
          bytes: input.data.length,
          width: 720,
          height: 1600,
          name: input.name,
        };
      },
    };
    const fakeCtx = {
      get(service) {
        if (service === 'tools') {
          return {
            register(def) {
              registeredTools.set(def.name, def);
              return () => registeredTools.delete(def.name);
            },
          };
        }
        if (service === 'attachments') return attachments;
        return undefined;
      },
      on() { return () => {}; },
    };

    const mounted = mountPhoneTools(fakeCtx, { socketPath, token });
    const shotTool = registeredTools.get('phone_screenshot');
    assert.ok(shotTool, 'phone_screenshot tool should be registered');

    const execVal = await shotTool.execute({ maxWidth: 720 }, { callId: 'c1' });
    assert.equal(savedCalls.length, 1);
    assert.equal(savedCalls[0].mediaType, 'image/jpeg');
    assert.equal(execVal.base64, undefined, 'raw base64 must be stripped after saving');
    assert.equal(execVal.image.attachmentId, 'att_phone_shot_001');

    const rendered = shotTool.output.render({}, execVal);
    assert.equal(rendered.length, 2);
    assert.equal(rendered[0].type, 'text');
    assert.equal(rendered[1].type, 'image');
    assert.equal(rendered[1].data, undefined, 'must not emit legacy inline data field');
    assert.equal(rendered[1].mimeType, undefined, 'must not emit legacy top-level mimeType field');
    assert.deepEqual(rendered[1].attachment, {
      attachmentId: 'att_phone_shot_001',
      mediaType: 'image/jpeg',
      bytes: Buffer.from(TINY_JPEG_B64, 'base64').length,
      width: 720,
      height: 1600,
      name: savedCalls[0].name,
    });

    mounted.dispose();
  } finally {
    await new Promise((resolve) => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
});

test('phone_screenshot never emits broken image block when attachments service is absent', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'gbridge-phone-noatt-'));
  const socketPath = join(dir, 'phone.sock');
  const token = 'test-secret-token';
  const server = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, width: 720, height: 1600, mimeType: 'image/jpeg', base64: TINY_JPEG_B64 }));
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));

  try {
    const registeredTools = new Map();
    const fakeCtx = {
      get(service) {
        if (service === 'tools') {
          return {
            register(def) {
              registeredTools.set(def.name, def);
              return () => {};
            },
          };
        }
        return undefined;
      },
      on() { return () => {}; },
    };
    const mounted = mountPhoneTools(fakeCtx, { socketPath, token });
    const shotTool = registeredTools.get('phone_screenshot');
    const execVal = await shotTool.execute({}, {});
    const rendered = shotTool.output.render({}, execVal);
    assert.equal(rendered.length, 1);
    assert.equal(rendered[0].type, 'text');
    assert.equal(rendered.some((b) => b.type === 'image'), false);
    mounted.dispose();
  } finally {
    await new Promise((resolve) => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
});

test('repairLegacyInlineImageSessions repairs poisoned zstd session files and is idempotent', async () => {
  const dshHome = mkdtempSync(join(tmpdir(), 'gbridge-repair-'));
  try {
    const sessionDir = join(dshHome, 'sessions', '--root-workspace--', 'session-7ee83566-872f-4ca3-9e54-9d166ece8d4c');
    mkdirSync(sessionDir, { recursive: true });
    const zstdPath = join(sessionDir, 'session.v4.jsonl.zstd');

    const header = JSON.stringify({ type: 'header', version: 4, sessionId: 'session-7ee83566' });
    const badEvent = JSON.stringify({
      seq: 12,
      type: 'message',
      data: {
        role: 'tool',
        message: {
          role: 'tool',
          toolCallId: 'call_1',
          content: [
            { type: 'text', text: '{"ok":true,"width":720,"height":1600}' },
            { type: 'image', data: TINY_JPEG_B64, mimeType: 'image/jpeg' },
          ],
        },
      },
    });
    const goodEvent = JSON.stringify({
      seq: 13,
      type: 'message',
      data: {
        role: 'tool',
        message: {
          role: 'tool',
          toolCallId: 'call_2',
          content: [
            {
              type: 'image',
              attachment: {
                attachmentId: 'att_existing_ok',
                mediaType: 'image/png',
                bytes: 42,
                width: 100,
                height: 100,
              },
            },
          ],
        },
      },
    });
    const checksumOpts = { params: { [zlibConstants.ZSTD_c_checksumFlag]: 1 } };
    // Write a real DSH-style concatenated multi-frame zstd log (frame 0 = header, frame 1 = bad tool event, frame 2 = good event)
    const multiFrame = Buffer.concat([
      zstdCompressSync(Buffer.from(`${header}\n`, 'utf8'), checksumOpts),
      zstdCompressSync(Buffer.from(`${badEvent}\n`, 'utf8'), checksumOpts),
      zstdCompressSync(Buffer.from(`${goodEvent}\n`, 'utf8'), checksumOpts),
    ]);
    writeFileSync(zstdPath, multiFrame);

    let savedCount = 0;
    const attachments = {
      async saveImage(input) {
        savedCount++;
        return {
          attachmentId: `att_repaired_${savedCount}`,
          mediaType: input.mediaType,
          bytes: input.data.length,
          width: 720,
          height: 1600,
          name: input.name,
        };
      },
    };

    const res1 = await repairLegacyInlineImageSessions({ dshHome, attachments });
    assert.equal(res1.scannedFiles, 1);
    assert.equal(res1.filesRepaired, 1);
    assert.equal(res1.repairedBlocks, 1);
    assert.equal(res1.fallbackBlocks, 0);

    const repairedBytes = readFileSync(zstdPath);
    assert.equal(scanZstdFrames(repairedBytes).frames.length, 3, 'must preserve multi-frame boundaries');
    const decoded = decodeConcatenatedZstd(repairedBytes).trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(decoded.length, 3);
    const repairedBlock = decoded[1].data.message.content[1];
    assert.equal(repairedBlock.type, 'image');
    assert.equal(repairedBlock.data, undefined);
    assert.equal(repairedBlock.mimeType, undefined);
    assert.equal(repairedBlock.attachment.attachmentId, 'att_repaired_1');
    assert.equal(decoded[2].data.message.content[0].attachment.attachmentId, 'att_existing_ok');

    // Second pass must be a clean no-op
    const res2 = await repairSessionFile(zstdPath, { attachments });
    assert.equal(res2.changed, false);
    assert.equal(savedCount, 1);
  } finally {
    rmSync(dshHome, { recursive: true, force: true });
  }
});

test('SessionNormalizer preserves intermediate prose before both tool calls and subsequent thinking', () => {
  const norm = new SessionNormalizer();
  const turns = norm.normalizeEvents('sess-1', [
    { seq: 1, type: 'turn/start', data: { turnId: 't1' } },
    { seq: 2, type: 'user/message', data: { message: { role: 'user', content: [{ type: 'text', text: '帮我检查一下' }] } } },
    {
      seq: 3,
      type: 'assistant/message',
      data: {
        message: {
          role: 'assistant',
          content: [
            { type: 'reasoning', text: '先看目录结构' },
            { type: 'text', text: '我先检查一下项目结构，请问需要修改配置文件吗？' },
          ],
        },
      },
    },
    {
      seq: 4,
      type: 'assistant/message',
      data: {
        message: {
          role: 'assistant',
          content: [
            { type: 'reasoning', text: '继续执行工具检查' },
            { type: 'tool-call', id: 'c1', name: 'ls', arguments: { path: '.' } },
          ],
        },
      },
    },
    {
      seq: 5,
      type: 'tool/result',
      data: { callId: 'c1', name: 'ls', output: 'ok' },
    },
    {
      seq: 6,
      type: 'assistant/message',
      data: {
        message: {
          role: 'assistant',
          content: [
            { type: 'text', text: '检查完成，一切正常。' },
          ],
        },
      },
    },
    { seq: 7, type: 'turn/end', data: { turnId: 't1', reason: 'completed' } },
  ]);

  assert.equal(turns.length, 1);
  const t = turns[0];
  assert.equal(t.assistantText, '检查完成，一切正常。');
  const proseSteps = t.steps.filter((s) => s.kind === 'reasoning' && (s.role === 'prose' || s.id.startsWith('narration-')));
  assert.equal(proseSteps.length, 1);
  assert.equal(proseSteps[0].text, '我先检查一下项目结构，请问需要修改配置文件吗？');
  // Chronological order: reasoning 1 -> intermediate prose -> reasoning 2 -> tool c1
  assert.equal(t.steps[0].kind, 'reasoning');
  assert.equal(t.steps[0].text, '先看目录结构');
  assert.equal(t.steps[1].role, 'prose');
  assert.equal(t.steps[2].text, '继续执行工具检查');
  assert.equal(t.steps[3].kind, 'tool');
});
