# GrassBag Android Runtime Toolchain

Physical 4-way separated storage layout managed by Kotlin `RuntimeController`:

```text
filesDir/
├─ volumes/
│  ├─ home/                 -> bind-mounted to /root (sessions, code, .ssh, .local/bin — never wiped!)
│  └─ dsh-slots/            -> A/B dual slots (slot-a, slot-b, active.json) for Zero-Patch DSH + dsh-gbridge
├─ containers/              -> Ubuntu 24.04 ARM64 stateless rootfs slots (r1 / r2 / current)
├─ shims/                   -> android-shim.mjs + droid-* CLI binaries (droid-clip/notify/share/vibrate/tts/info)
└─ run/                     -> 0700 private socket dir (bridge.sock, phone-control.sock, droid.sock)
```

## Building Bundled Assets

```bash
bash runtime/scripts/build-runtime-bundle.sh
```

Produces `shims.tar.gz`, `engine-init.tar.gz`, and `runtime-manifest.json` inside `app/android/app/src/main/assets/runtime/` for `BundledApkAssetSource`, while online upgrades seamlessly stream from `RemoteHttpAssetSource` with SHA-256 verification and 60-second crash auto-rollback to LKG.
