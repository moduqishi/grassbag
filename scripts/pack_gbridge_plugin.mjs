import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_PLUGIN_DIR = path.join(ROOT_DIR, 'packages', 'dsh-gbridge');

export const REQUIRED_TARBALL_ENTRIES = [
  'package/package.json',
  'package/cordis.patch.yml',
  'package/icon.svg',
  'package/lib/index.js',
  'package/lib/client.js',
  'package/lib/content-contract.js',
  'package/lib/diagnostics.js',
  'package/lib/qr-svg.js',
  'package/lib/pairing-ui.js',
  'package/locale/zh.json',
  'package/locale/en.json',
  'package/test/dsh-contract-roundtrip.test.mjs',
  'package/test/reliability-audit.test.mjs',
];

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      options[key] = 'true';
    } else {
      options[key] = next;
      i += 1;
    }
  }
  return options;
}

export function packGbridgePlugin({
  pluginDir = DEFAULT_PLUGIN_DIR,
  outPath,
} = {}) {
  const pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'));
  if (pkg.private === true) {
    throw new Error('packages/dsh-gbridge/package.json must not be marked private');
  }
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gbridge-pack-'));
  try {
    const packStdout = execFileSync(
      'npm',
      ['pack', '--pack-destination', tmpDir],
      { cwd: pluginDir, encoding: 'utf8', env: { ...process.env, COPYFILE_DISABLE: '1' } },
    ).trim();
    const tgzFiles = fs.readdirSync(tmpDir).filter((f) => f.endsWith('.tgz'));
    const generated = tgzFiles[0] || packStdout.split('\n').pop()?.trim();
    if (!generated) {
      throw new Error('npm pack did not emit a .tgz archive');
    }
    const generatedPath = path.join(tmpDir, generated);
    const listOut = execFileSync('tar', ['-tzf', generatedPath], { encoding: 'utf8' });
    const entries = new Set(listOut.split(/\r?\n/).filter(Boolean));
    for (const reqEntry of REQUIRED_TARBALL_ENTRIES) {
      if (!entries.has(reqEntry)) {
        throw new Error(`dsh-gbridge.tgz missing required entry: ${reqEntry}`);
      }
    }
    for (const entry of entries) {
      if (entry.includes('.DS_Store') || entry.includes('node_modules/')) {
        throw new Error(`dsh-gbridge.tgz contains disallowed file: ${entry}`);
      }
    }

    const finalOut = path.resolve(outPath || path.join(tmpDir, 'dsh-gbridge.tgz'));
    fs.mkdirSync(path.dirname(finalOut), { recursive: true });
    fs.copyFileSync(generatedPath, finalOut);

    const bytes = fs.statSync(finalOut).size;
    const sha256 = crypto.createHash('sha256').update(fs.readFileSync(finalOut)).digest('hex');
    return {
      outPath: finalOut,
      fileName: path.basename(finalOut),
      version: pkg.version,
      bytes,
      sha256,
      entriesCount: entries.size,
    };
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const outPath = opts.out || path.join(os.tmpdir(), 'dsh-gbridge.tgz');
  const result = packGbridgePlugin({ outPath });
  if (opts['github-output']) {
    const lines = [
      `plugin_name=${result.fileName}`,
      `plugin_path=${result.outPath}`,
      `plugin_sha=${result.sha256}`,
      `plugin_bytes=${result.bytes}`,
      `plugin_version=${result.version}`,
    ];
    fs.appendFileSync(opts['github-output'], `${lines.join('\n')}\n`, 'utf8');
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (err) {
    process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
    process.exitCode = 1;
  }
}
