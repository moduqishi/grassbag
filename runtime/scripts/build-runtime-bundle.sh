#!/usr/bin/env bash
# Build reproducible GrassBag Android ARM64 runtime assets.
#
# Modes:
#   --thin (default):
#     Packages ONLY the tiny ~260KB APK-coupled overlays (`shims.gbag`, `gbridge.gbag`)
#     and generates `runtime-manifest.json` referencing the immutable remote runtime release
#     pinned in `runtime/runtime-lock.json` (`base-arm64.gbag` + `engine-init.gbag`).
#     Keeps Android APK lean (~29 MB) with on-demand resumable download + SHA-256 verification.
#
#   --full | --bundle-all:
#     Builds full `base-arm64.gbag` (Ubuntu + Node 24) and `engine-init.gbag` (DSH) alongside
#     `shims.gbag`, `gbridge.gbag`, and `runtime-manifest.json` (used for publishing GitHub
#     Runtime Releases or optional offline-bundled local APKs).
#
# Options:
#   --fetch                  Download upstream Ubuntu/Node & npm install DSH if missing (--full)
#   --update-lock            Rewrite `runtime/runtime-lock.json` with newly built hashes (--full)
#   --runtime-tag <tag>      Override immutable release tag (default from runtime-lock.json)
#   --github-repo <o/r>      Override GitHub repository slug (default from runtime-lock.json)
#   --out <dir> | <dir>      Output directory (default: app/android/app/src/main/assets/runtime)
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK_FILE="$ROOT_DIR/runtime/runtime-lock.json"

MODE="thin"
FETCH_MISSING=0
UPDATE_LOCK=0
OUT_DIR=""
RUNTIME_TAG_OVERRIDE=""
GITHUB_REPO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --thin)
      MODE="thin"
      shift
      ;;
    --full|--bundle-all)
      MODE="full"
      shift
      ;;
    --fetch)
      FETCH_MISSING=1
      shift
      ;;
    --update-lock)
      UPDATE_LOCK=1
      shift
      ;;
    --runtime-tag)
      RUNTIME_TAG_OVERRIDE="${2:-}"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO_OVERRIDE="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
      fi
      shift
      ;;
  esac
done

OUT_DIR="${OUT_DIR:-$ROOT_DIR/app/android/app/src/main/assets/runtime}"
STAGING_DIR="$ROOT_DIR/runtime/.staging"
ARCH="${ARCH:-arm64}"

# Read defaults from runtime/runtime-lock.json if present
read_lock_field() {
  node -e "
    const fs = require('node:fs');
    const p = process.argv[1];
    const path = process.argv[2].split('.');
    if (!fs.existsSync(p)) process.exit(0);
    let cur = JSON.parse(fs.readFileSync(p, 'utf8'));
    for (const k of path) cur = cur && cur[k];
    if (cur !== undefined && cur !== null) {
      process.stdout.write(typeof cur === 'string' ? cur : JSON.stringify(cur));
    }
  " "$LOCK_FILE" "$1"
}

RUNTIME_TAG="${RUNTIME_TAG_OVERRIDE:-${RUNTIME_TAG:-$(read_lock_field runtimeTag)}}"
RUNTIME_TAG="${RUNTIME_TAG:-runtime-arm64-r2}"
GITHUB_REPO="${GITHUB_REPO_OVERRIDE:-${GITHUB_REPO:-$(read_lock_field githubRepo)}}"
GITHUB_REPO="${GITHUB_REPO:-moduqishi/grassbag}"
DSH_VERSION="${DSH_VERSION:-$(read_lock_field dshVersion)}"
DSH_VERSION="${DSH_VERSION:-0.2.2-rc.5}"
DSH_SPEC="${DSH_SPEC:-@deepseek-ai/dsh@${DSH_VERSION}}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04.5}"
UBUNTU_SERIES="${UBUNTU_SERIES:-24.04}"
NODE_VERSION="${NODE_VERSION:-$(read_lock_field nodeVersion)}"
NODE_VERSION="${NODE_VERSION:-24.22.3}"
CONTAINER_VERSION="${CONTAINER_VERSION:-$(read_lock_field containerVersion)}"
CONTAINER_VERSION="${CONTAINER_VERSION:-Ubuntu ${UBUNTU_RELEASE} · r2}"
ADDON_BUILTIN_VERSION="${ADDON_BUILTIN_VERSION:-0.1.10}"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_bytes() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[GrassBag Runtime] Mode: $MODE | Output: $OUT_DIR | Tag: $RUNTIME_TAG"

# 1. Always package tiny APK-coupled shims & droid-* CLI wrappers (~156 KB)
SHIMS_TAR="$OUT_DIR/shims.gbag"
tar -C "$ROOT_DIR/runtime/shims" -czf "$SHIMS_TAR" .
SHIMS_SHA="$(sha256_file "$SHIMS_TAR")"
SHIMS_BYTES="$(file_bytes "$SHIMS_TAR")"
echo "[GrassBag Runtime] shims.gbag: $SHIMS_BYTES bytes"

# 2. Always package tiny APK-coupled dsh-gbridge zero-patch bridge (~130 KB, including self-tests)
BRIDGE_STAGE="$WORK_DIR/dsh-gbridge"
mkdir -p "$BRIDGE_STAGE"
cp -R "$ROOT_DIR/packages/dsh-gbridge/package.json" \
      "$ROOT_DIR/packages/dsh-gbridge/lib" \
      "$ROOT_DIR/packages/dsh-gbridge/test" \
      "$ROOT_DIR/packages/dsh-gbridge/locale" \
      "$ROOT_DIR/packages/dsh-gbridge/icon.svg" \
      "$BRIDGE_STAGE/"
if [[ -f "$ROOT_DIR/packages/gbridge-protocol/schema/gbridge-v1.schema.json" ]]; then
  cp "$ROOT_DIR/packages/gbridge-protocol/schema/gbridge-v1.schema.json" "$BRIDGE_STAGE/gbridge-v1.schema.json"
fi
cat > "$BRIDGE_STAGE/cordis.patch.yml" <<'EOF'
- insert:
  - name: /opt/dsh-slots/current/dsh-gbridge/lib/index.js
EOF
GBRIDGE_TAR="$OUT_DIR/gbridge.gbag"
tar -C "$BRIDGE_STAGE" -czf "$GBRIDGE_TAR" .
GBRIDGE_SHA="$(sha256_file "$GBRIDGE_TAR")"
GBRIDGE_BYTES="$(file_bytes "$GBRIDGE_TAR")"
echo "[GrassBag Runtime] gbridge.gbag: $GBRIDGE_BYTES bytes"

BRIDGE_VERSION="$(node -p "JSON.parse(require('node:fs').readFileSync('$ROOT_DIR/packages/dsh-gbridge/package.json','utf8')).version" 2>/dev/null || echo '0.2.0')"

DELIVERY_MODE="remote"
BASE_SHA=""
BASE_BYTES=""
ENGINE_SHA=""
ENGINE_BYTES=""

if [[ "$MODE" == "thin" ]]; then
  # Remove any stale heavy offline bundles so APK stays ~29 MB!
  rm -f "$OUT_DIR/base-arm64.gbag" "$OUT_DIR/engine-init.gbag"
  if [[ ! -f "$LOCK_FILE" ]]; then
    echo "ERROR: Missing $LOCK_FILE required for --thin manifest generation" >&2
    exit 1
  fi
  BASE_SHA="$(read_lock_field artifacts.baseRootfs.sha256)"
  BASE_BYTES="$(read_lock_field artifacts.baseRootfs.bytes)"
  ENGINE_SHA="$(read_lock_field artifacts.engineInit.sha256)"
  ENGINE_BYTES="$(read_lock_field artifacts.engineInit.bytes)"
  if [[ -z "$BASE_SHA" || -z "$BASE_BYTES" || -z "$ENGINE_SHA" || -z "$ENGINE_BYTES" ]]; then
    echo "ERROR: Incomplete artifacts metadata in $LOCK_FILE" >&2
    exit 1
  fi
  DELIVERY_MODE="remote"
else
  DELIVERY_MODE="bundled"
  UBUNTU_TAR="$STAGING_DIR/dl/ubuntu-base-${UBUNTU_RELEASE}-base-arm64.tar.gz"
  NODE_TAR="$STAGING_DIR/dl/node-v${NODE_VERSION}-linux-arm64.tar.xz"
  DSH_LINUX_DIR="$STAGING_DIR/dsh-linux-arm64"

  TAR_EXTRACT_FLAGS=()
  if tar --version 2>/dev/null | grep -qi gnu; then
    TAR_EXTRACT_FLAGS=(--no-same-owner)
  fi

  if [[ "$FETCH_MISSING" == "1" ]]; then
    mkdir -p "$STAGING_DIR/dl"
    if [[ ! -f "$UBUNTU_TAR" ]]; then
      UBUNTU_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_SERIES}/release/ubuntu-base-${UBUNTU_RELEASE}-base-arm64.tar.gz"
      echo "[GrassBag Runtime] Downloading Ubuntu ${UBUNTU_RELEASE} ARM64 base..."
      curl -fsSL --retry 3 --retry-delay 2 "$UBUNTU_URL" -o "${UBUNTU_TAR}.part"
      mv "${UBUNTU_TAR}.part" "$UBUNTU_TAR"
    fi
    if [[ ! -f "$NODE_TAR" ]]; then
      NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz"
      echo "[GrassBag Runtime] Downloading Node.js v${NODE_VERSION} ARM64..."
      curl -fsSL --retry 3 --retry-delay 2 "$NODE_URL" -o "${NODE_TAR}.part"
      mv "${NODE_TAR}.part" "$NODE_TAR"
    fi
    if [[ ! -d "$DSH_LINUX_DIR/node_modules/@deepseek-ai/dsh" ]]; then
      echo "[GrassBag Runtime] Installing ${DSH_SPEC} for linux/arm64..."
      mkdir -p "$DSH_LINUX_DIR"
      cat > "$DSH_LINUX_DIR/package.json" <<EOF
{
  "name": "dsh-linux-arm64",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {
    "@deepseek-ai/dsh": "${DSH_VERSION}",
    "node-addon-require-builtin-linux-arm64-gnu": "^${ADDON_BUILTIN_VERSION}"
  }
}
EOF
      (
        cd "$DSH_LINUX_DIR"
        npm install --os=linux --cpu=arm64 --omit=dev --no-audit --no-fund --force
      )
    fi
  fi

  if [[ ! -f "$UBUNTU_TAR" ]]; then
    echo "ERROR: Missing $UBUNTU_TAR (pass --fetch to download automatically)" >&2
    exit 1
  fi
  if [[ ! -f "$NODE_TAR" ]]; then
    echo "ERROR: Missing $NODE_TAR (pass --fetch to download automatically)" >&2
    exit 1
  fi
  if [[ ! -d "$DSH_LINUX_DIR/node_modules/@deepseek-ai/dsh" ]]; then
    echo "ERROR: Missing $DSH_LINUX_DIR/node_modules/@deepseek-ai/dsh (pass --fetch to install automatically)" >&2
    exit 1
  fi

  # 3. Build base-arm64.gbag (Ubuntu ARM64 + Node ARM64)
  BASE_STAGE="$WORK_DIR/base-arm64"
  mkdir -p "$BASE_STAGE"
  echo "[GrassBag Runtime] Staging Ubuntu $UBUNTU_RELEASE ARM64..."
  tar ${TAR_EXTRACT_FLAGS[@]+"${TAR_EXTRACT_FLAGS[@]}"} -xzf "$UBUNTU_TAR" -C "$BASE_STAGE" \
    --exclude='./dev/*' --exclude='dev/*' \
    --exclude='./usr/share/doc/*' --exclude='./usr/share/man/*' \
    --exclude='./usr/share/info/*' --exclude='./usr/share/locale/*'

  echo "[GrassBag Runtime] Overlaying Node.js v$NODE_VERSION ARM64..."
  NODE_EXTRACT="$WORK_DIR/node-extract"
  mkdir -p "$NODE_EXTRACT"
  tar ${TAR_EXTRACT_FLAGS[@]+"${TAR_EXTRACT_FLAGS[@]}"} -xJf "$NODE_TAR" -C "$NODE_EXTRACT"
  NODE_SRC="$NODE_EXTRACT/node-v${NODE_VERSION}-linux-arm64"
  mkdir -p "$BASE_STAGE/usr/local/bin" "$BASE_STAGE/usr/local/lib"
  cp -a "$NODE_SRC/bin/node" "$BASE_STAGE/usr/local/bin/node"
  cp -a "$NODE_SRC/lib/node_modules" "$BASE_STAGE/usr/local/lib/node_modules"
  ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$BASE_STAGE/usr/local/bin/npm"
  ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$BASE_STAGE/usr/local/bin/npx"

  mkdir -p "$BASE_STAGE/dev" "$BASE_STAGE/proc" "$BASE_STAGE/sys" "$BASE_STAGE/tmp" \
           "$BASE_STAGE/root" "$BASE_STAGE/opt/dsh-slots" "$BASE_STAGE/opt/shims" \
           "$BASE_STAGE/run/grassbag" "$BASE_STAGE/etc/profile.d"
  chmod 1777 "$BASE_STAGE/tmp"
  cat > "$BASE_STAGE/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
  cat > "$BASE_STAGE/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF
  cat > "$BASE_STAGE/etc/profile.d/grassbag.sh" <<'EOF'
export PATH="/usr/local/bin:/opt/shims/droid-bin:/root/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export DSH_HOME="/root/.dsh"
export SHELL="/bin/bash"
export TERM="${TERM:-xterm-256color}"
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
export CURL_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export REQUESTS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export GIT_SSL_CAINFO="/etc/ssl/certs/ca-certificates.crt"
EOF

  BASE_TAR="$OUT_DIR/base-arm64.gbag"
  echo "[GrassBag Runtime] Compressing base-arm64.gbag..."
  tar -C "$BASE_STAGE" -czf "$BASE_TAR" .
  BASE_SHA="$(sha256_file "$BASE_TAR")"
  BASE_BYTES="$(file_bytes "$BASE_TAR")"
  echo "[GrassBag Runtime] base-arm64.gbag: $((BASE_BYTES / 1024 / 1024)) MiB ($BASE_BYTES bytes)"

  # 4. Stage REAL @deepseek-ai/dsh (Linux ARM64) + dsh-gbridge
  ENGINE_STAGE="$WORK_DIR/engine-init"
  mkdir -p "$ENGINE_STAGE"
  echo "[GrassBag Runtime] Staging REAL $DSH_SPEC (Linux ARM64)..."
  cp -a "$DSH_LINUX_DIR/package.json" "$ENGINE_STAGE/"
  cp -a "$DSH_LINUX_DIR/node_modules" "$ENGINE_STAGE/node_modules"

  rm -rf \
    "$ENGINE_STAGE/node_modules/@deepseek-ai/libreoffice-kit-wasm" \
    "$ENGINE_STAGE/node_modules/@deepseek-ai/libreoffice-kit-linux-arm64" \
    "$ENGINE_STAGE/node_modules/@deepseek-ai/libreoffice-kit-darwin-arm64" \
    "$ENGINE_STAGE/node_modules/@deepseek-ai/dsh-experimental-cua-macos" \
    "$ENGINE_STAGE/node_modules/sherpa-onnx-linux-arm64" \
    "$ENGINE_STAGE/node_modules/sherpa-onnx-darwin-arm64" \
    "$ENGINE_STAGE/node_modules/node-pty/prebuilds/darwin-arm64" \
    "$ENGINE_STAGE/node_modules/node-pty/prebuilds/darwin-x64" \
    "$ENGINE_STAGE/node_modules/node-pty/prebuilds/linux-x64" \
    "$ENGINE_STAGE/node_modules/node-pty/prebuilds/win32-arm64" \
    "$ENGINE_STAGE/node_modules/node-pty/prebuilds/win32-x64" \
    "$ENGINE_STAGE/node_modules/@deepseek-ai/libreoffice-kit/frame-forwarding/prebuilds"

  find "$ENGINE_STAGE/node_modules" \( -name "*.map" -o -name "*.d.ts" -o -name "*.d.mts" -o -name "*.d.cts" \) -delete
  find "$ENGINE_STAGE/node_modules/@deepseek-ai" -maxdepth 2 -type d \( -name "src" -o -name "docs" \) -exec rm -rf {} +

  cp -a "$BRIDGE_STAGE" "$ENGINE_STAGE/dsh-gbridge"

  ENGINE_TAR="$OUT_DIR/engine-init.gbag"
  if [[ "${SKIP_ENGINE_INIT:-0}" == "1" && -f "$ENGINE_TAR" ]]; then
    echo "[GrassBag Runtime] Reusing existing engine-init.gbag (SKIP_ENGINE_INIT=1)"
  else
    echo "[GrassBag Runtime] Compressing engine-init.gbag..."
    tar -C "$ENGINE_STAGE" -czf "$ENGINE_TAR" .
  fi
  ENGINE_SHA="$(sha256_file "$ENGINE_TAR")"
  ENGINE_BYTES="$(file_bytes "$ENGINE_TAR")"
  echo "[GrassBag Runtime] engine-init.gbag: $((ENGINE_BYTES / 1024 / 1024)) MiB ($ENGINE_BYTES bytes)"

  if [[ "$UPDATE_LOCK" == "1" ]]; then
    node -e "
      const fs = require('node:fs');
      const lock = {
        schemaVersion: 4,
        arch: process.argv[2],
        runtimeTag: process.argv[3],
        githubRepo: process.argv[4],
        containerVersion: process.argv[5],
        nodeVersion: process.argv[6],
        dshVersion: process.argv[7],
        dshSpec: process.argv[8],
        mirrorPrefixes: ['https://gh-proxy.com/', 'https://ghfast.top/'],
        artifacts: {
          baseRootfs: {
            filename: 'base-arm64.gbag',
            sha256: process.argv[9],
            bytes: Number(process.argv[10]),
          },
          engineInit: {
            filename: 'engine-init.gbag',
            sha256: process.argv[11],
            bytes: Number(process.argv[12]),
          },
        },
      };
      fs.writeFileSync(process.argv[1], JSON.stringify(lock, null, 2) + '\n', 'utf8');
    " "$LOCK_FILE" "$ARCH" "$RUNTIME_TAG" "$GITHUB_REPO" "$CONTAINER_VERSION" \
      "$NODE_VERSION" "$DSH_VERSION" "$DSH_SPEC" "$BASE_SHA" "$BASE_BYTES" "$ENGINE_SHA" "$ENGINE_BYTES"
    echo "[GrassBag Runtime] Updated $LOCK_FILE"
  fi
fi

# 5. Emit schemaVersion 4 runtime-manifest.json consumed by Android RuntimeController
node -e "
  const fs = require('node:fs');
  const [
    manifestOut, lockFile, arch, runtimeTag, githubRepo, containerVersion,
    nodeVersion, dshVersion, dshSpec, bridgeVersion, delivery,
    shimsSha, shimsBytes, gbridgeSha, gbridgeBytes,
    baseSha, baseBytes, engineSha, engineBytes,
  ] = process.argv.slice(1);

  let mirrorPrefixes = ['https://gh-proxy.com/', 'https://ghfast.top/'];
  if (fs.existsSync(lockFile)) {
    try {
      const lock = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
      if (Array.isArray(lock.mirrorPrefixes) && lock.mirrorPrefixes.length > 0) {
        mirrorPrefixes = lock.mirrorPrefixes.filter((s) => typeof s === 'string' && s.trim().length > 0);
      }
    } catch {}
  }

  const directBase = 'https://github.com/' + githubRepo + '/releases/download/' + runtimeTag;
  const buildUrls = (filename) => [
    ...mirrorPrefixes.map((p) => p.replace(/\/+$/, '') + '/' + directBase + '/' + filename),
    directBase + '/' + filename,
  ];

  const manifest = {
    schemaVersion: 4,
    arch,
    runtimeTag,
    githubRepo,
    delivery,
    containerVersion,
    nodeVersion,
    dshVersion,
    dshSpec,
    bridgeVersion,
    mirrorPrefixes,
    artifacts: {
      shims: {
        asset: 'runtime/shims.gbag',
        filename: 'shims.gbag',
        delivery: 'bundled',
        sha256: shimsSha,
        bytes: Number(shimsBytes),
      },
      gbridge: {
        asset: 'runtime/gbridge.gbag',
        filename: 'gbridge.gbag',
        delivery: 'bundled',
        sha256: gbridgeSha,
        bytes: Number(gbridgeBytes),
      },
      baseRootfs: {
        asset: 'runtime/base-arm64.gbag',
        filename: 'base-arm64.gbag',
        delivery,
        sha256: baseSha,
        bytes: Number(baseBytes),
        urls: buildUrls('base-arm64.gbag'),
      },
      engineInit: {
        asset: 'runtime/engine-init.gbag',
        filename: 'engine-init.gbag',
        delivery,
        sha256: engineSha,
        bytes: Number(engineBytes),
        urls: buildUrls('engine-init.gbag'),
      },
    },
  };

  fs.writeFileSync(manifestOut, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
" "$OUT_DIR/runtime-manifest.json" "$LOCK_FILE" "$ARCH" "$RUNTIME_TAG" "$GITHUB_REPO" \
  "$CONTAINER_VERSION" "$NODE_VERSION" "$DSH_VERSION" "$DSH_SPEC" "$BRIDGE_VERSION" \
  "$DELIVERY_MODE" "$SHIMS_SHA" "$SHIMS_BYTES" "$GBRIDGE_SHA" "$GBRIDGE_BYTES" \
  "$BASE_SHA" "$BASE_BYTES" "$ENGINE_SHA" "$ENGINE_BYTES"

echo "[GrassBag Runtime] Manifest written to $OUT_DIR/runtime-manifest.json"
ls -lh "$OUT_DIR"
