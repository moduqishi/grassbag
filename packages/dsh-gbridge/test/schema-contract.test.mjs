import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildCapabilities } from '../lib/domains/meta.js';
import { SduiRegistry } from '../lib/sdui.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = resolve(HERE, '../../gbridge-protocol/schema/gbridge-v1.schema.json');

test('capabilities response matches gbridge-v1.schema.json required fields and enums', () => {
  const schema = JSON.parse(readFileSync(SCHEMA_PATH, 'utf8'));
  const capDef = schema.$defs.CapabilitiesResponse;
  const mockGateway = {
    has: (ep) => ep === 'session/list' || ep === 'session/prompt',
    listEndpoints: () => ['session/list', 'session/prompt'],
  };
  const caps = buildCapabilities({
    ctx: { get: () => undefined },
    gateway: mockGateway,
    bridgeVersion: '0.1.0',
    bootId: 'boot-schema-1',
    phoneState: { active: false, reason: 'disabled' },
    isLocalAndroid: false,
  });

  for (const key of capDef.required) {
    assert.ok(Object.hasOwn(caps, key), `Missing required capabilities field: ${key}`);
  }
  assert.equal(caps.v, capDef.properties.v.const);
  assert.equal(caps.transport.wsPath, capDef.properties.transport.properties.wsPath.const);
  for (const hostKey of capDef.properties.host.required) {
    assert.ok(Object.hasOwn(caps.host, hostKey), `Missing host field: ${hostKey}`);
  }
  for (const [domain, val] of Object.entries(caps.domains)) {
    assert.equal(typeof val.ok, 'boolean', `Domain ${domain} must expose boolean ok`);
  }
});

test('SDUI node types stay within gbridge-v1.schema.json allowed enum', async () => {
  const schema = JSON.parse(readFileSync(SCHEMA_PATH, 'utf8'));
  const allowedTypes = new Set(schema.$defs.SduiNode.properties.type.enum);
  const sdui = new SduiRegistry();
  sdui.register({
    id: 'sample',
    title: 'Sample',
    render: () => ({
      type: 'column',
      children: [
        { type: 'metric', label: 'A', value: '1' },
        { type: 'card', title: 'B', children: [{ type: 'markdown', value: '**hi**' }] },
      ],
    }),
  });
  const view = await sdui.renderView('sample');
  const walk = (node) => {
    assert.ok(allowedTypes.has(node.type), `Invalid SDUI node type: ${node.type}`);
    if (Array.isArray(node.children)) node.children.forEach(walk);
  };
  walk(view.root);
});
