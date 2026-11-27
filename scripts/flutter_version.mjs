import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION_PATTERN =
  /^version:\s*(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\+(?<build>\d+)\s*$/m;
const VERSION_SEGMENT_BASE = 10;
const DEFAULT_PUBSPEC = 'app/pubspec.yaml';

export function parseVersionLine(contents) {
  const match = contents.match(VERSION_PATTERN);
  if (!match?.groups) {
    throw new Error('Could not find a Flutter version line like "version: x.y.z+n".');
  }

  return {
    major: Number.parseInt(match.groups.major, 10),
    minor: Number.parseInt(match.groups.minor, 10),
    patch: Number.parseInt(match.groups.patch, 10),
    build: Number.parseInt(match.groups.build, 10),
    raw: match[0],
    index: match.index ?? -1,
  };
}

export function formatVersion({ major, minor, patch, build }) {
  return `${major}.${minor}.${patch}+${build}`;
}

export function formatVersionName({ major, minor, patch }) {
  return `${major}.${minor}.${patch}`;
}

export function parseVersionName(value) {
  const match = String(value || '').trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) {
    throw new Error(`Expected a version like "x.y.z", got "${value}".`);
  }

  return {
    major: Number.parseInt(match[1], 10),
    minor: Number.parseInt(match[2], 10),
    patch: Number.parseInt(match[3], 10),
  };
}

export function formatVersionLabel({ major, minor, patch, build }) {
  return `${major}.${minor}.${patch}(${build})`;
}

export function bumpPatchVersion(version) {
  let major = version.major;
  let minor = version.minor;
  let patch = version.patch + 1;

  if (patch >= VERSION_SEGMENT_BASE) {
    patch = 0;
    minor += 1;
  }

  if (minor >= VERSION_SEGMENT_BASE) {
    minor = 0;
    major += 1;
  }

  return {
    major,
    minor,
    patch,
    build: version.build + 1,
  };
}

export function replaceVersionLine(contents, nextVersion) {
  if (!VERSION_PATTERN.test(contents)) {
    throw new Error('Unable to replace version line in pubspec.yaml.');
  }

  return contents.replace(VERSION_PATTERN, `version: ${formatVersion(nextVersion)}`);
}

export function prepareStableVersion(currentVersion, baselineVersion, tag) {
  const normalizedTag = String(tag || '').trim();
  if (!normalizedTag) {
    throw new Error('Missing required stable tag.');
  }
  const versionName = normalizedTag.startsWith('v') ? normalizedTag.slice(1) : normalizedTag;
  const targetVersion = parseVersionName(versionName);
  const currentVersionName = formatVersionName(currentVersion);
  const baselineVersionName = formatVersionName(baselineVersion);
  const highestKnownBuild = Math.max(currentVersion.build, baselineVersion.build);

  if (baselineVersionName === versionName) {
    return {
      ...baselineVersion,
      build: highestKnownBuild,
    };
  }

  if (currentVersionName === versionName && currentVersion.build >= baselineVersion.build) {
    return {
      ...currentVersion,
      build: highestKnownBuild,
    };
  }

  return {
    ...targetVersion,
    build: highestKnownBuild + 1,
  };
}

export function parseAndroidMetadata(contents) {
  const payload = JSON.parse(contents);
  const element = payload?.elements?.[0];
  if (!element) {
    throw new Error('Android output metadata does not contain a release element.');
  }

  return {
    versionCode: Number.parseInt(`${element.versionCode}`, 10),
    versionName: `${element.versionName ?? ''}`,
    outputFile: `${element.outputFile ?? ''}`,
  };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = rest[index + 1];
    if (!next || next.startsWith('--')) {
      options[key] = 'true';
      continue;
    }
    options[key] = next;
    index += 1;
  }
  return { command, options };
}

function writeGithubOutput(outputPath, values) {
  if (!outputPath) return;
  const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`);
  fs.appendFileSync(outputPath, `${lines.join('\n')}\n`, 'utf8');
}

function ensureFile(filePath) {
  const absolutePath = path.resolve(filePath);
  if (!fs.existsSync(absolutePath)) {
    throw new Error(`File not found: ${absolutePath}`);
  }
  return absolutePath;
}

function bumpCommand(options) {
  const filePath = ensureFile(options.file ?? DEFAULT_PUBSPEC);
  const contents = fs.readFileSync(filePath, 'utf8');
  const current = parseVersionLine(contents);
  const next = bumpPatchVersion(current);
  const nextVersion = formatVersion(next);
  const nextVersionName = formatVersionName(next);
  const nextVersionLabel = formatVersionLabel(next);
  const expectedTag = options['expected-tag'];

  if (expectedTag && expectedTag !== `v${nextVersionName}`) {
    throw new Error(
      `Expected release tag ${expectedTag} to match computed version v${nextVersionName}.`,
    );
  }

  const updatedContents = replaceVersionLine(contents, next);
  if (updatedContents !== contents) {
    fs.writeFileSync(filePath, updatedContents, 'utf8');
  }

  const channel = options.channel ?? 'stable';
  const releaseTag = channel === 'stable' ? `v${nextVersionName}` : `beta-v${nextVersion}`;
  const outputs = {
    CURRENT_VERSION_NAME: formatVersionName(current),
    CURRENT_BUILD_NUMBER: `${current.build}`,
    CURRENT_VERSION: formatVersion(current),
    NEXT_VERSION_NAME: nextVersionName,
    NEXT_BUILD_NUMBER: `${next.build}`,
    NEXT_VERSION: nextVersion,
    NEXT_VERSION_LABEL: nextVersionLabel,
    RELEASE_TAG: releaseTag,
    VERSION_CHANGED: updatedContents === contents ? 'false' : 'true',
  };

  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function prepareReleaseCommand(options) {
  const filePath = ensureFile(options.file ?? DEFAULT_PUBSPEC);
  const baselinePath = ensureFile(options['baseline-file'] ?? filePath);
  const tag = `${options.tag ?? ''}`.trim();
  if (!tag) {
    throw new Error('Missing required --tag value.');
  }

  const currentContents = fs.readFileSync(filePath, 'utf8');
  const baselineContents = fs.readFileSync(baselinePath, 'utf8');
  const currentVersion = parseVersionLine(currentContents);
  const baselineVersion = parseVersionLine(baselineContents);
  const nextVersion = prepareStableVersion(currentVersion, baselineVersion, tag);
  const updatedContents = replaceVersionLine(currentContents, nextVersion);

  if (updatedContents !== currentContents) {
    fs.writeFileSync(filePath, updatedContents, 'utf8');
  }

  const outputs = {
    TAG: tag,
    VERSION_NAME: formatVersionName(nextVersion),
    BUILD_NUMBER: `${nextVersion.build}`,
    VERSION: formatVersion(nextVersion),
    VERSION_LABEL: formatVersionLabel(nextVersion),
    VERSION_CHANGED: updatedContents === currentContents ? 'false' : 'true',
  };

  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function applyVersionCommand(options) {
  const filePath = ensureFile(options.file ?? DEFAULT_PUBSPEC);
  const sourceFilePath = ensureFile(options['source-file'] ?? filePath);
  const targetContents = fs.readFileSync(filePath, 'utf8');
  const sourceContents = fs.readFileSync(sourceFilePath, 'utf8');
  const sourceVersion = parseVersionLine(sourceContents);
  const updatedContents = replaceVersionLine(targetContents, sourceVersion);

  if (updatedContents !== targetContents) {
    fs.writeFileSync(filePath, updatedContents, 'utf8');
  }

  const outputs = {
    VERSION_NAME: formatVersionName(sourceVersion),
    BUILD_NUMBER: `${sourceVersion.build}`,
    VERSION: formatVersion(sourceVersion),
    VERSION_LABEL: formatVersionLabel(sourceVersion),
    VERSION_CHANGED: updatedContents === targetContents ? 'false' : 'true',
  };

  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function verifyAndroidMetadataCommand(options) {
  const metadataPath = ensureFile(options.file);
  const pubspecPath = ensureFile(options.pubspec ?? DEFAULT_PUBSPEC);
  const metadata = parseAndroidMetadata(fs.readFileSync(metadataPath, 'utf8'));
  const version = parseVersionLine(fs.readFileSync(pubspecPath, 'utf8'));
  const versionName = formatVersionName(version);
  const versionLabel = formatVersionLabel(version);
  const versionNameSuffix = `${options['version-name-suffix'] ?? ''}`;
  const expectedVersionName =
    versionNameSuffix === '' ? versionName : `${versionName}${versionNameSuffix}`;

  if (metadata.versionName !== expectedVersionName) {
    throw new Error(
      `APK versionName ${metadata.versionName} does not match pubspec version ${expectedVersionName}.`,
    );
  }

  if (metadata.versionCode !== version.build) {
    throw new Error(
      `APK versionCode ${metadata.versionCode} does not match pubspec build ${version.build}.`,
    );
  }

  const outputs = {
    APK_VERSION_NAME: metadata.versionName,
    APK_VERSION_CODE: `${metadata.versionCode}`,
    APK_OUTPUT_FILE: metadata.outputFile,
    PUBSPEC_VERSION_LABEL: versionLabel,
  };
  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function readCommand(options) {
  const filePath = ensureFile(options.file ?? DEFAULT_PUBSPEC);
  const contents = fs.readFileSync(filePath, 'utf8');
  const version = parseVersionLine(contents);
  const outputs = {
    VERSION_NAME: formatVersionName(version),
    BUILD_NUMBER: `${version.build}`,
    VERSION: formatVersion(version),
    VERSION_LABEL: formatVersionLabel(version),
  };
  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function verifyTagCommand(options) {
  const filePath = ensureFile(options.file ?? DEFAULT_PUBSPEC);
  const contents = fs.readFileSync(filePath, 'utf8');
  const version = parseVersionLine(contents);
  const expectedTag = `v${formatVersionName(version)}`;
  const actualTag = `${options.tag ?? ''}`.trim();

  if (!actualTag) {
    throw new Error('Missing required --tag value.');
  }

  if (actualTag !== expectedTag) {
    throw new Error(`Expected git tag ${actualTag} to match pubspec version tag ${expectedTag}.`);
  }

  const outputs = {
    TAG: actualTag,
    EXPECTED_TAG: expectedTag,
    VERSION_NAME: formatVersionName(version),
    BUILD_NUMBER: `${version.build}`,
    VERSION: formatVersion(version),
    VERSION_LABEL: formatVersionLabel(version),
  };
  writeGithubOutput(options['github-output'] ?? process.env.GITHUB_OUTPUT, outputs);
  process.stdout.write(`${JSON.stringify(outputs, null, 2)}\n`);
}

function main() {
  const { command, options } = parseArgs(process.argv.slice(2));
  switch (command) {
    case 'bump':
      bumpCommand(options);
      break;
    case 'read':
      readCommand(options);
      break;
    case 'verify-tag':
      verifyTagCommand(options);
      break;
    case 'prepare-release':
      prepareReleaseCommand(options);
      break;
    case 'apply-version':
      applyVersionCommand(options);
      break;
    case 'verify-android-metadata':
      verifyAndroidMetadataCommand(options);
      break;
    default:
      throw new Error(
        'Unknown command. Use one of: bump, read, verify-tag, prepare-release, apply-version, verify-android-metadata.',
      );
  }
}

const isCliEntrypoint =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isCliEntrypoint) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : `${error}`}\n`);
    process.exitCode = 1;
  }
}
