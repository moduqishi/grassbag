#!/usr/bin/env bash
# Reclaim unused disk space on GitHub Actions ubuntu-latest runners before
# building GrassBag's offline ARM64 Linux runtime bundle + Flutter Release APK.
set -uo pipefail

if [[ "${RUNNER_OS:-}" != "Linux" ]]; then
  echo "Not running on GitHub Actions Linux runner (RUNNER_OS=${RUNNER_OS:-unknown}); skipping disk cleanup."
  exit 0
fi

echo "== Disk usage before cleanup =="
df -h /

sudo rm -rf \
  /usr/share/dotnet \
  /opt/ghc \
  /usr/local/.ghcup \
  /usr/local/share/boost \
  "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}/CodeQL" \
  "${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}/system-images" \
  "${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}/emulator" \
  "${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}/sources"

if command -v docker >/dev/null 2>&1; then
  sudo docker image prune -af >/dev/null 2>&1 || true
fi

echo "== Disk usage after cleanup =="
df -h /
