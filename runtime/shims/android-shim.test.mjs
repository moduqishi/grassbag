import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const execFileAsync = promisify(execFile);
const SHIM_PATH = join(dirname(fileURLToPath(import.meta.url)), 'android-shim.mjs');

async function runWithMockFetch(scriptBody) {
  const runner = `
    const calls = [];
    let handler = null;
    globalThis.fetch = async (input, init) => {
      const url = typeof input === 'string' ? input : (input?.url ?? String(input));
      const method = (init?.method ?? input?.method ?? 'GET').toUpperCase();
      const hdrs = new Headers(init?.headers !== undefined ? init.headers : (input?.headers ?? undefined));
      calls.push({ url, method, headers: Object.fromEntries(hdrs.entries()) });
      return handler(input, init, calls.length);
    };
    await import(${JSON.stringify(SHIM_PATH)});
    ${scriptBody}
  `;
  const { stdout } = await execFileAsync(process.execPath, ['--input-type=module', '-e', runner], {
    timeout: 15000,
    env: { ...process.env, GBRIDGE_LOCAL_ANDROID: '1' },
  });
  return JSON.parse(stdout.trim());
}

test('android-shim never retries non-idempotent POST requests on transport failure', async () => {
  const res = await runWithMockFetch(`
    handler = async () => {
      const err = new TypeError('fetch failed');
      err.cause = Object.assign(new Error('socket hang up'), { code: 'ECONNRESET' });
      throw err;
    };
    let threw = false;
    try {
      await globalThis.fetch('https://api.deepseek.com/v1/messages', {
        method: 'POST',
        headers: { authorization: 'Bearer sk-test', 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'deepseek-chat' }),
      });
    } catch {
      threw = true;
    }
    console.log(JSON.stringify({ threw, calls }));
  `);
  assert.equal(res.threw, true);
  assert.equal(res.calls.length, 1);
  assert.equal(res.calls[0].method, 'POST');
});

test('android-shim retries safe GET Request and preserves all original Request headers', async () => {
  const res = await runWithMockFetch(`
    handler = async (_input, _init, attempt) => {
      if (attempt === 1) {
        const err = new TypeError('fetch failed');
        err.cause = Object.assign(new Error('ECONNRESET'), { code: 'ECONNRESET' });
        throw err;
      }
      return new Response('ok', { status: 200 });
    };
    const req = new Request('https://api.deepseek.com/v1/models', {
      method: 'GET',
      headers: {
        authorization: 'Bearer sk-keep-header',
        'x-custom-trace': 'trace-99',
      },
    });
    const resp = await globalThis.fetch(req);
    console.log(JSON.stringify({ status: resp.status, calls }));
  `);
  assert.equal(res.status, 200);
  assert.equal(res.calls.length, 2);
  assert.equal(res.calls[1].method, 'GET');
  assert.equal(res.calls[1].headers.authorization, 'Bearer sk-keep-header');
  assert.equal(res.calls[1].headers['x-custom-trace'], 'trace-99');
  assert.equal(res.calls[1].headers.connection, 'close');
});

test('android-shim never retries fetch(Request) when Request method is POST', async () => {
  const res = await runWithMockFetch(`
    handler = async () => {
      const err = new TypeError('fetch failed');
      err.cause = Object.assign(new Error('other side closed'), { code: 'UND_ERR_SOCKET' });
      throw err;
    };
    const req = new Request('https://api.deepseek.com/v1/chat/completions', {
      method: 'POST',
      headers: { authorization: 'Bearer sk-post' },
    });
    let threw = false;
    try {
      await globalThis.fetch(req);
    } catch {
      threw = true;
    }
    console.log(JSON.stringify({ threw, calls }));
  `);
  assert.equal(res.threw, true);
  assert.equal(res.calls.length, 1);
  assert.equal(res.calls[0].method, 'POST');
});
