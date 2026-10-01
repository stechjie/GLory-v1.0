# GLory Godot 4.7 server patch

This server-only fork admits new UDP endpoints only when their first packet has a DTLS ClientHello envelope. Established and pending endpoints bypass the admission check. Mbed TLS still validates all cryptographic content, cookies and certificates. Non-admitted packets have rate-bounded metadata diagnostics; real handshake failures retain ERROR output and gain the remote endpoint.

The patch also makes `CookieContextMbedTLS::clear()` idempotent: `DTLSServerMbedTLS::stop()` clears it before its destructor clears it again. It does not relax mutex validation.

Godot 4.7 release templates disable explicit project/script paths by default. This source-only server patch enables `OVERRIDE_PATH_ENABLED` in its two Linux consumers (`main.cpp` and `project_settings.cpp`), preserving the existing `--path` and `--script` deployment/test workflow. Other translation units do not use this feature, so the change can be built incrementally without recompiling unrelated modules.

Pinned base: `5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88` (Godot 4.7 stable).

Build on Ubuntu 22.04 x86_64, matching production glibc 2.35:

```sh
./deploy/engine/build_linux.sh /tmp/unique-empty-build-dir
python3 deploy/engine/tests/run_lifecycle.py \
  --godot /tmp/unique-empty-build-dir/godot-5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88/bin/godot.linuxbsd.template_release.x86_64 \
  --out /tmp/dtls-results
python3 deploy/engine/tests/check_server_logging.py \
  --godot /tmp/unique-empty-build-dir/godot-5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88/bin/godot.linuxbsd.template_release.x86_64 \
  --service scripts/multiplayer/ClientLogService.gd
```

The script verifies the official source archive hash, applies the patch without fuzz, runs the native admission matrix and builds with SCons 4.8.1. Run in a disposable container; the script never deploys. The initial validated container base was `ubuntu:22.04@sha256:b8b6ee6aa931ecd9d0d952abc34dc0e5f7c6a30c6bb71b079fe399fde0329c02`. Exact apt package versions are not pinned, so record the resulting binary hash for each build.

The lifecycle suite generates temporary keys, listens only on loopback, reuses a client port through nine disconnect/reconnect cycles, transfers 16 KiB encrypted data, retains a concurrent healthy client, submits stale/non-handshake records, and rejects plaintext and incorrect certificate pins. It fails on unexpected log errors even when connection assertions pass. The deliberately wrong certificate case must continue to fail cryptographically. No production credentials or player state are used.

Run `tests/run_game_checks.py --source /path/to/checkout --godot /path/to/binary --out /path/to/results` inside a container started with `--network=none`. It derives a temporary source-only project, supplies fresh global-class metadata, isolates user data and omits the client font autoload. The checkout must include `officetest/OfficeTestSim.gd`: this pure simulation fixture is added only to the test project and class cache, not the production bundle. It runs 14 network, logging and battle checks, including the current upstream battle regressions. Each case streams its log to disk so a parse failure is visible before the timeout. Test scenes own their listening sockets: adding `--dedicated-server` would incorrectly start another server on their shared NetworkService. The final settlement UI suite requires the full client resources and is run separately with the desktop engine. The exact deployment bundle must still pass its own default-entry cold start without these test-only changes.

Cloud Shell `/tmp` is ephemeral. Keep the build directory and evidence on its persistent home volume, and copy final hashes, logs and results to the delivery workspace before restarting or releasing the session.

Before production promotion: test the actual binary on the server OS in an isolated network namespace, cold-start the exact source bundle, verify its manifest, verify no peers/rooms, preserve user directory and TLS credentials, install a versioned binary and retain the old systemd configuration for rollback. Check public DTLS heartbeat and post-start journal. Never use a fresh certificate in the production bundle.

Historical attribution and actual rollout evidence: [audit](../../docs/DTLS逐条核查与修复_20260930.md).

## iOS CoreAudio recovery template

`godot-4.7-ios-audio-recovery.patch` targets the same Godot 4.7 source commit. It checks actual mixer callbacks only while foreground and focused, and performs bounded RemoteIO reinitialization on a stall. It does not keep background microphone capture running.

From the outer delivery workspace, using a Python environment with SCons:

```sh
python3 tools/build_ios_audio_template.py --source /path/to/godot-5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88
python3 tools/glory_ios_build.py --check --method ad-hoc --version 0.0.15
```

Stock templates remain unchanged. Output goes to `build/ios-audio-templates/4.7.stable`; this arm64 release replacement supports this project's GL Compatibility renderer, not Metal/Vulkan. `glory-engine.json` records patch, library and archive hashes. Packaging requires matching patch/archive evidence and verifies the recovery marker and voice framework in the final IPA. After native changes, verify both audible recovery and return latency on a physical device.
