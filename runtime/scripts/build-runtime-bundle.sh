#!/usr/bin/env bash
# Build reproducible GrassBag Android ARM64 runtime assets:
#   - base-arm64.tar.gz     (Ubuntu 24.04.5 ARM64 + Node.js v24.22.3 ARM64 + DNS/hosts)
#   - engine-init.tar.gz    (REAL unmodified @deepseek-ai/dsh@0.2.2-rc.5 Linux ARM64 + dsh-gbridge)
#   - shims.tar.gz          (android-shim.mjs + droid-* CLI wrappers)
#   - runtime-manifest.json (SHA-256 + byte sizes + versions consumed by RuntimeController.kt)
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FETCH_MISSING=0
OUT_DIR=""
for arg in "$@"; do
  case "$arg" in
    --fetch)
      FETCH_MISSING=1
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$arg"
      fi
      ;;
  esac
done
OUT_DIR="${OUT_DIR:-$ROOT_DIR/app/android/app/src/main/assets/runtime}"
STAGING_DIR="$ROOT_DIR/runtime/.staging"
ARCH="${ARCH:-arm64}"
DSH_VERSION="${DSH_VERSION:-0.2.2-rc.5}"
DSH_SPEC="${DSH_SPEC:-@deepseek-ai/dsh@${DSH_VERSION}}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04.5}"
UBUNTU_SERIES="${UBUNTU_SERIES:-24.04}"
NODE_VERSION="${NODE_VERSION:-24.22.3}"
ADDON_BUILTIN_VERSION="${ADDON_BUILTIN_VERSION:-0.1.10}"

UBUNTU_TAR="$STAGING_DIR/dl/ubuntu-base-${UBUNTU_RELEASE}-base-arm64.tar.gz"
NODE_TAR="$STAGING_DIR/dl/node-v${NODE_VERSION}-linux-arm64.tar.xz"
DSH_LINUX_DIR="$STAGING_DIR/dsh-linux-arm64"

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

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[GrassBag Runtime] Output directory: $OUT_DIR"

# 1. Package shims & droid-* CLI wrappers (.gbag prevents Android aapt2 from stripping .gz!)
SHIMS_TAR="$OUT_DIR/shims.gbag"
tar -C "$ROOT_DIR/runtime/shims" -czf "$SHIMS_TAR" .
SHIMS_SHA="$(sha256_file "$SHIMS_TAR")"
SHIMS_BYTES="$(file_bytes "$SHIMS_TAR")"
echo "[GrassBag Runtime] shims.gbag: $SHIMS_BYTES bytes"

# 2. Build base-arm64.tar.gz (Ubuntu 24.04.5 ARM64 + Node 24.22.3 ARM64)
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

# Ensure container directories, DNS, hosts, and root shell profile exist
mkdir -p "$BASE_STAGE/dev" "$BASE_STAGE/proc" "$BASE_STAGE/sys" "$BASE_STAGE/tmp" \
         "$BASE_STAGE/root" "$BASE_STAGE/opt/dsh-slots" "$BASE_STAGE/opt/shims" \
         "$BASE_STAGE/run/grassbag" "$BASE_STAGE/etc"
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

# 3. Stage REAL @deepseek-ai/dsh@0.2.2-rc.5 (Linux ARM64) + dsh-gbridge
ENGINE_STAGE="$WORK_DIR/engine-init"
mkdir -p "$ENGINE_STAGE"
echo "[GrassBag Runtime] Staging REAL $DSH_SPEC (Linux ARM64)..."
cp -a "$DSH_LINUX_DIR/package.json" "$ENGINE_STAGE/"
cp -a "$DSH_LINUX_DIR/node_modules" "$ENGINE_STAGE/node_modules"

# Prune non-ARM64/non-Linux prebuilds, source maps, TS decls, and bulky desktop-only optional binaries
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

# Copy zero-patch dsh-gbridge into slot root AND package as a fast ~60KB incremental overlay (`gbridge.gbag`)
BRIDGE_STAGE="$ENGINE_STAGE/dsh-gbridge"
mkdir -p "$BRIDGE_STAGE"
cp -R "$ROOT_DIR/packages/dsh-gbridge/package.json" \
      "$ROOT_DIR/packages/dsh-gbridge/lib" \
      "$ROOT_DIR/packages/dsh-gbridge/locale" \
      "$ROOT_DIR/packages/dsh-gbridge/icon.svg" \
      "$BRIDGE_STAGE/"
cat > "$BRIDGE_STAGE/cordis.patch.yml" <<'EOF'
- insert:
  - name: /opt/dsh-slots/current/dsh-gbridge/lib/index.js
EOF

GBRIDGE_TAR="$OUT_DIR/gbridge.gbag"
tar -C "$BRIDGE_STAGE" -czf "$GBRIDGE_TAR" .
GBRIDGE_SHA="$(sha256_file "$GBRIDGE_TAR")"
GBRIDGE_BYTES="$(file_bytes "$GBRIDGE_TAR")"
echo "[GrassBag Runtime] gbridge.gbag: $GBRIDGE_BYTES bytes"

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

BRIDGE_VERSION="$(node -p "JSON.parse(require('node:fs').readFileSync('$ROOT_DIR/packages/dsh-gbridge/package.json','utf8')).version" 2>/dev/null || echo '0.2.0')"
# 4. Emit runtime-manifest.json consumed by Android RuntimeController
cat > "$OUT_DIR/runtime-manifest.json" <<EOF
{
  "schemaVersion": 3,
  "arch": "$ARCH",
  "containerVersion": "Ubuntu $UBUNTU_RELEASE · r2",
  "nodeVersion": "$NODE_VERSION",
  "dshVersion": "$DSH_VERSION",
  "dshSpec": "$DSH_SPEC",
  "bridgeVersion": "$BRIDGE_VERSION",
  "artifacts": {
    "shims": {
      "asset": "runtime/shims.gbag",
      "sha256": "$SHIMS_SHA",
      "bytes": $SHIMS_BYTES
    },
    "gbridge": {
      "asset": "runtime/gbridge.gbag",
      "sha256": "$GBRIDGE_SHA",
      "bytes": $GBRIDGE_BYTES
    },
    "baseRootfs": {
      "asset": "runtime/base-arm64.gbag",
      "sha256": "$BASE_SHA",
      "bytes": $BASE_BYTES
    },
    "engineInit": {
      "asset": "runtime/engine-init.gbag",
      "sha256": "$ENGINE_SHA",
      "bytes": $ENGINE_BYTES
    }
  }
}
EOF

echo "[GrassBag Runtime] Manifest written to $OUT_DIR/runtime-manifest.json"
ls -lh "$OUT_DIR"
