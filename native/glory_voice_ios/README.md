# iOS team voice

The iOS GDExtension registers the same `GloryVoice` singleton as Android and
Windows. LiveKit Swift handles WebRTC capture, echo cancellation and playback.
The bridge uses `AVAudioSession` for the native microphone authorization prompt;
`VoiceService` waits for that result even before the room token arrives.

## Build

Requires Xcode with the iPhoneOS SDK, Python 3 and SCons. On macOS:

```sh
python3 -m pip install scons==4.11.1
python3 native/glory_voice_ios/build.py --work-dir /absolute/path/to/ios-voice-build
```

The script pins godot-cpp to the 4.5 stable commit and LiveKit Swift to 2.17.0,
builds iPhoneOS arm64 with a minimum deployment target of iOS 15, and writes
three frameworks plus `build-manifest.json` into `addons/glory_voice/bin/ios`.
The manifest records source and binary hashes. No signing keys or server voice
credentials are required to compile this component. The app export signs the
embedded frameworks with its own distribution identity.

The `.gdextension` declares the iOS library and both dynamic dependencies.
The `glory_voice` export plugin supplies the microphone purpose text. Set the
iOS preset's minimum version to 15.0 or later. Inspect the **exported app** for
a nonempty `NSMicrophoneUsageDescription`, all three frameworks, the LiveKit
resource bundle, and successful deep signature verification. A successful
native compile alone does not verify the exported app.

## Verification

`tools/voice_check.tscn` tests native permission pending/grant/deny behavior,
authorization before a voice token arrives, and late authorization after the
player turns voice off. Existing Android/Windows state-machine checks remain.

On a physical iPhone, separately verify the first permission prompt, rejection,
subsequent Settings grant, two-device team voice, Listen/Talk toggles, member
mute, headset/speaker routing, and background/foreground behavior. Background
audio is intentionally not enabled: leaving or backgrounding disconnects voice.
Only explicit Talk mode can publish a microphone track. Room credentials still
come from the game server; this plugin does not contain a LiveKit API secret.

This build targets physical devices. It does not contain an iOS Simulator slice.
On 2026-09-27, iPhone build 16 passed the native component probe: system
permission, room connection, microphone publication with 1,271 non-silent frames
received by a separate peer, and mute observed on both endpoints. The tester
also confirmed hearing two remotely published tones through the speaker.
No recording was saved. Full game integration, cellular switching, rejection
recovery, headset routing and background behavior remain separate checks.
