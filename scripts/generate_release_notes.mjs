import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith('--')) {
      options[key] = 'true';
      continue;
    }
    options[key] = next;
    index += 1;
  }
  return options;
}

function runGit(args) {
  try {
    return execFileSync('git', args, { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

function listTagsByRecency(channel) {
  const pattern = channel === 'stable' ? 'v*' : 'beta-v*';
  const output = runGit([
    'for-each-ref',
    '--sort=-creatordate',
    '--format=%(refname:short)',
    `refs/tags/${pattern}`,
  ]);
  return output ? output.split('\n').filter(Boolean) : [];
}

function getPreviousTag(channel, currentTag) {
  return listTagsByRecency(channel).find((tag) => tag !== currentTag) ?? '';
}

function getCommitLines(previousTag) {
  const range = previousTag ? `${previousTag}..HEAD` : 'HEAD';
  const output = runGit(['log', range, '--pretty=format:%h%x09%s']);
  return output ? output.split('\n').filter(Boolean) : [];
}

function readRuntimeInfo(manifestPath) {
  if (!manifestPath || !fs.existsSync(manifestPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const channel = options.channel ?? 'stable';
  const currentTag = options.tag ?? '';
  const versionLabel = options.version ?? '';
  const apkName = options['apk-name'] ?? '';
  const apkSha = options['apk-sha256'] ?? '';
  const manifestPath = options['runtime-manifest'] ?? '';
  const outputPath = path.resolve(options.output ?? 'release_notes.md');

  const previousTag = getPreviousTag(channel, currentTag);
  const commits = getCommitLines(previousTag);
  const runtime = readRuntimeInfo(manifestPath);

  const heading = channel === 'stable' ? '正式版发布' : '测试版发布';
  const lines = [
    `## ${heading}`,
    '',
    `- 版本：\`${versionLabel}\``,
    `- 发布标签：\`${currentTag}\``,
    '- 目标架构：`Android arm64-v8a`',
  ];

  if (previousTag) {
    lines.push(`- 对比基线：\`${previousTag}\``);
  }
  if (runtime) {
    lines.push(
      `- 内置运行时：\`${runtime.containerVersion || 'Ubuntu 24.04.5'}\` · \`Node ${runtime.nodeVersion || '24.22.3'}\` · \`DSH ${runtime.dshVersion || '0.2.2-rc.5'}\``,
    );
  }
  if (apkName) {
    lines.push(`- 安装包：\`${apkName}\``);
  }
  if (apkSha) {
    lines.push(`- SHA-256：\`${apkSha}\``);
  }

  lines.push('', '## 更新内容', '');
  if (commits.length === 0) {
    lines.push('- 初始版本发布与构建验证。');
  } else {
    for (const commit of commits.slice(0, 25)) {
      const [, subject = commit] = commit.split('\t');
      lines.push(`- ${subject}`);
    }
  }

  fs.writeFileSync(outputPath, `${lines.join('\n')}\n`, 'utf8');
  process.stdout.write(`${outputPath}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : `${error}`}\n`);
  process.exitCode = 1;
}
