# GrassBag Android Runtime Toolchain

Physical 4-way separated storage layout managed by Kotlin `RuntimeController`:

```text
filesDir/
├─ volumes/
│  ├─ home/                 -> bind-mounted to /root (sessions, code, .ssh, .local/bin — never wiped!)
│  └─ dsh-slots/            -> A/B dual slots (slot-a, slot-b, runtime-state.json) for Zero-Patch DSH + dsh-gbridge
├─ containers/              -> Ubuntu 24.04.5 ARM64 stateless rootfs + Node 24
├─ shims/                   -> android-shim.mjs + droid-* CLI binaries (droid-clip/notify/share/vibrate/tts/info)
├─ runtime-downloads/       -> resumable `.part` cache during on-demand download (auto-deleted after extract)
└─ run/                     -> 0700 private socket dir (bridge.sock, phone-control.sock, droid.sock)
```

## Packaging Modes

### 1. Lean Online-Download APK (Default — ~29 MB APK)

```bash
bash runtime/scripts/build-runtime-bundle.sh --thin
```

Bundles only `shims.gbag` (~156 KB), `gbridge.gbag` (~102 KB), and `runtime-manifest.json` (referencing pinned SHA-256 + mirror URLs from `runtime/runtime-lock.json`). On first use of Local Mode, Android downloads `base-arm64.gbag` (~72 MB) and `engine-init.gbag` (~116 MB) with HTTP `Range` resume, mirror failover, and SHA-256 verification.

### 2. Full Runtime Release / Offline Test Bundle

```bash
bash runtime/scripts/build-runtime-bundle.sh --full --fetch --update-lock
```

Builds full `base-arm64.gbag`, `engine-init.gbag`, `shims.gbag`, `gbridge.gbag`, and `runtime-manifest.json`, updating `runtime/runtime-lock.json`.
