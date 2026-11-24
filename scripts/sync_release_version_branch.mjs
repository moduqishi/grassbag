import fs from 'node:fs';
import os from 'node:os';
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

function runGit(args, options = {}) {
  const output = execFileSync('git', args, {
    encoding: 'utf8',
    stdio: options.stdio ?? 'pipe',
    cwd: options.cwd,
  });
  return typeof output === 'string' ? output.trim() : '';
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const branch = options.branch ?? 'release-version';
  const sourceFile = options['source-file'] ?? 'app/pubspec.yaml';
  const targetFile = options['target-file'] ?? sourceFile;
  const message = options.message ?? 'chore: sync release version state';
  const repoRoot = runGit(['rev-parse', '--show-toplevel']);
  const sourcePath = path.resolve(repoRoot, sourceFile);

  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Source file not found: ${sourcePath}`);
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'grassbag-release-version-'));
  const cleanup = () => {
    try {
      runGit(['worktree', 'remove', '--force', tempDir], { cwd: repoRoot, stdio: 'ignore' });
    } catch {
      // ignore cleanup failures
    }
    try {
      fs.rmSync(tempDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  };

  try {
    try {
      runGit(['fetch', 'origin', `${branch}:refs/remotes/origin/${branch}`], {
        cwd: repoRoot,
        stdio: 'ignore',
      });
    } catch {
      // branch might not exist yet
    }

    let hasRemoteBranch = true;
    try {
      runGit(['show-ref', '--verify', '--quiet', `refs/remotes/origin/${branch}`], {
        cwd: repoRoot,
        stdio: 'ignore',
      });
    } catch {
      hasRemoteBranch = false;
    }

    if (hasRemoteBranch) {
      runGit(['worktree', 'add', '--detach', tempDir, `refs/remotes/origin/${branch}`], {
        cwd: repoRoot,
        stdio: 'ignore',
      });
      runGit(['checkout', '-B', branch, `refs/remotes/origin/${branch}`], {
        cwd: tempDir,
        stdio: 'ignore',
      });
    } else {
      runGit(['worktree', 'add', '--detach', tempDir, 'HEAD'], {
        cwd: repoRoot,
        stdio: 'ignore',
      });
      runGit(['checkout', '--orphan', branch], { cwd: tempDir, stdio: 'ignore' });
      try {
        runGit(['rm', '-rf', '.'], { cwd: tempDir, stdio: 'ignore' });
      } catch {
        // ignore empty tree cleanup failures
      }
    }

    const targetPath = path.resolve(tempDir, targetFile);
    fs.mkdirSync(path.dirname(targetPath), { recursive: true });
    fs.copyFileSync(sourcePath, targetPath);

    const readmePath = path.resolve(tempDir, 'README.md');
    if (!fs.existsSync(readmePath)) {
      fs.writeFileSync(
        readmePath,
        [
          '# GrassBag Release Version State',
          '',
          'This orphan branch stores the authoritative `app/pubspec.yaml` version baseline used by',
          'GitHub Actions to auto-increment `versionName` and Android `versionCode` without polluting `main`.',
          '',
        ].join('\n'),
        'utf8',
      );
    }

    runGit(['add', targetFile, 'README.md'], { cwd: tempDir, stdio: 'ignore' });

    let hasChanges = true;
    try {
      runGit(['diff', '--cached', '--quiet'], { cwd: tempDir, stdio: 'ignore' });
      hasChanges = false;
    } catch {
      hasChanges = true;
    }

    if (!hasChanges) {
      process.stdout.write(`No version state changes for ${branch}.\n`);
      return;
    }

    runGit(['config', 'user.name', 'github-actions[bot]'], { cwd: tempDir, stdio: 'ignore' });
    runGit(
      ['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com'],
      { cwd: tempDir, stdio: 'ignore' },
    );
    runGit(['commit', '-m', message], { cwd: tempDir, stdio: 'ignore' });
    runGit(['push', 'origin', `HEAD:${branch}`], { cwd: tempDir, stdio: 'ignore' });
    process.stdout.write(`Synced ${targetFile} to ${branch}.\n`);
  } finally {
    cleanup();
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : `${error}`}\n`);
  process.exitCode = 1;
}
