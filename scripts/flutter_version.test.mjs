import assert from 'node:assert/strict';
import test from 'node:test';

import {
  bumpPatchVersion,
  formatVersion,
  formatVersionLabel,
  parseAndroidMetadata,
  parseVersionLine,
  prepareStableVersion,
  replaceVersionLine,
} from './flutter_version.mjs';

test('parseVersionLine & replaceVersionLine round-trip cleanly', () => {
  const sample = 'name: grassbag\nversion: 0.1.0+1\nenvironment:\n  sdk: ^3.6.0\n';
  const parsed = parseVersionLine(sample);
  assert.deepEqual(
    { major: parsed.major, minor: parsed.minor, patch: parsed.patch, build: parsed.build },
    { major: 0, minor: 1, patch: 0, build: 1 },
  );
  const next = bumpPatchVersion(parsed);
  assert.equal(formatVersion(next), '0.1.1+2');
  assert.equal(formatVersionLabel(next), '0.1.1(2)');
  const replaced = replaceVersionLine(sample, next);
  assert.match(replaced, /^version: 0\.1\.1\+2$/m);
});

test('bumpPatchVersion rolls over minor and major at base 10', () => {
  assert.deepEqual(bumpPatchVersion({ major: 0, minor: 1, patch: 9, build: 10 }), {
    major: 0,
    minor: 2,
    patch: 0,
    build: 11,
  });
  assert.deepEqual(bumpPatchVersion({ major: 0, minor: 9, patch: 9, build: 99 }), {
    major: 1,
    minor: 0,
    patch: 0,
    build: 100,
  });
});

test('prepareStableVersion keeps build number monotonic across release-version baseline', () => {
  const mainVer = { major: 0, minor: 1, patch: 0, build: 1 };
  const branchVer = { major: 0, minor: 1, patch: 4, build: 5 };

  // Next auto-bumped patch release -> build 6
  const nextPatch = prepareStableVersion(mainVer, branchVer, 'v0.1.5');
  assert.deepEqual(nextPatch, { major: 0, minor: 1, patch: 5, build: 6 });

  // Re-publishing exact baseline tag keeps highest known build
  const sameBaseline = prepareStableVersion(mainVer, branchVer, 'v0.1.4');
  assert.deepEqual(sameBaseline, { major: 0, minor: 1, patch: 4, build: 5 });

  // Explicit major/minor jump increments from baseline build
  const manualMinor = prepareStableVersion(mainVer, branchVer, 'v0.2.0');
  assert.deepEqual(manualMinor, { major: 0, minor: 2, patch: 0, build: 6 });
});

test('parseAndroidMetadata extracts versionCode and versionName', () => {
  const raw = JSON.stringify({
    version: 3,
    elements: [
      {
        versionCode: 7,
        versionName: '0.1.6',
        outputFile: 'app-release.apk',
      },
    ],
  });
  assert.deepEqual(parseAndroidMetadata(raw), {
    versionCode: 7,
    versionName: '0.1.6',
    outputFile: 'app-release.apk',
  });
});
