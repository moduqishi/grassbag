#!/usr/bin/env node
/**
 * Shared client for GrassBag `droid-*` CLI commands.
 * Communicates strictly over Android private 0600 UDS (`DROID_BRIDGE_SOCKET`)
 * with per-boot Bearer token (`DROID_BRIDGE_TOKEN`).
 */
import { request } from 'node:http';

const socketPath = process.env.DROID_BRIDGE_SOCKET;
const token = process.env.DROID_BRIDGE_TOKEN;
const action = process.argv[2];

if (!socketPath || !token) {
  console.error('droid-rpc: DROID_BRIDGE_SOCKET and DROID_BRIDGE_TOKEN must be set');
  process.exit(2);
}

const STDIN_ACTIONS = new Set(['clip', 'notify', 'share', 'tts']);

async function readStdinIfPiped(shouldRead) {
  if (!shouldRead || process.stdin.isTTY) return '';
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return Buffer.concat(chunks).toString('utf8');
}

const args = process.argv.slice(3);
const needsStdin = STDIN_ACTIONS.has(action) && (args.length === 0 || (action === 'notify' && args.length < 2));
const stdinText = await readStdinIfPiped(needsStdin);
const body = JSON.stringify({ action, args, stdin: stdinText });

const req = request(
  {
    socketPath,
    path: '/v1/droid',
    method: 'POST',
    timeout: 10_000,
    headers: {
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
      authorization: `Bearer ${token}`,
    },
  },
  (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      try {
        const json = JSON.parse(text || '{}');
        if (res.statusCode >= 200 && res.statusCode < 300 && json.ok !== false) {
          if (typeof json.output === 'string' && json.output.length > 0) {
            process.stdout.write(json.output.endsWith('\n') ? json.output : `${json.output}\n`);
          }
          process.exit(0);
        } else {
          console.error(json?.error?.message || json?.reason || `droid-rpc failed (${res.statusCode})`);
          process.exit(1);
        }
      } catch {
        process.stdout.write(text);
        process.exit(res.statusCode >= 200 && res.statusCode < 300 ? 0 : 1);
      }
    });
  },
);

req.on('timeout', () => {
  req.destroy(new Error('request timed out after 10s'));
});

req.on('error', (err) => {
  console.error(`droid-rpc socket error: ${err.message}`);
  process.exit(1);
});
req.end(body);
