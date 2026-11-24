import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { packGbridgePlugin } from './pack_gbridge_plugin.mjs';

test('packGbridgePlugin builds verified zero-bloat dsh-gbridge.tgz for GitHub Releases', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gbridge-pack-test-'));
  const outPath = path.join(dir, 'dsh-gbridge.tgz');
  try {
    const res = packGbridgePlugin({ outPath });
    assert.equal(res.fileName, 'dsh-gbridge.tgz');
    assert.ok(fs.existsSync(outPath));
    assert.ok(res.bytes > 5000 && res.bytes < 512 * 1024, `unexpected tarball size: ${res.bytes}`);
    assert.match(res.sha256, /^[0-9a-f]{64}$/);
    assert.ok(res.entriesCount >= 9);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
