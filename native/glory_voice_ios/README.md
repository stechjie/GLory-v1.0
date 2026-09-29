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

## Full-duplex game audio policy (2026-09-29)

The game owns other audio in the same process. LiveKit automatic session
configuration and deactivation are disabled. The bridge owns activation and
pins play-and-record / default mode with speaker, Bluetooth and mix-with-others
options after voice is first used, so voice engine changes do not replace the
shared session policy or deactivate Godot output.
Before connecting, `setPlatformVoiceProcessingAllowed(false)` selects WebRTC
software echo cancellation/noise suppression/gain control. This avoids Apple's
Voice Processing I/O output changes and other-audio ducking; the SDK's software
capture session uses play-and-record with media mode and speaker preference.
Do not disable echo cancellation entirely or mute remote tracks while publishing.
All remote tracks remain subscribed; participant mute remains independent.
Old connection/publish/disconnect tasks finish before a replacement room connects.

MusicService attenuates only its player to 0.5 linear gain when native status
confirms a connected, enabled microphone in Talk mode. Listen, Off, failed or
pending capture, and disconnect restore 1.0. It does not restart the track,
change the Master bus, or override the music-off setting. This music behavior
is shared with Android; Android's native voice routing is unchanged.

Diagnosis is code-based, not a reproduced device root cause: the previous SDK
policy allowed whole-session deactivation and iOS voice-processing output
changes. These are plausible causes of lost game audio / quieter remote audio.
The existing per-participant volume loop already supports multiple speakers.
Native status now includes session mode, platform-processing policy, and the
number of subscribed remote audio tracks to help distinguish routing from
subscription problems in a device report.

Validation: build the arm64 framework with `build.py`; run
`tools/voice_music_check.tscn` and `tools/voice_check.tscn`. The former exercises
confirmed vs pending mic, reconnect, mute/listen, leave, music continuity and two
unmuted peers with a fake bridge. Neither headless checks nor a framework build
prove audible full-duplex behavior on iOS.

Device acceptance for the next IPA (no iPhone available during this fix):
- Play BGM, join with two other teammates, and hear both before and after Talk.
- Have all three speak concurrently for 30 seconds; each must hear both others.
- Verify BGM remains audible at about half gain while talking and restores on
  Listen/Off/disconnect; music disabled in settings must stay silent.
- Repeat mic toggles, room switching, foreground/background, speaker, wired and
  Bluetooth headset routes. Check echo/feedback under software AEC, especially
  loud game effects. Local microphone monitoring is intentionally not added.

## Audience task cancellation regression (0.0.11)

Changing audience intentionally cancels an in-flight microphone task. Cancellation
must not set `mic_failed`, otherwise VoiceService treats the intentional scope
change as a capture failure and drops Talk to Listen. Stale/cancelled audience
operations are checked before SDK mutations and may not report current errors.
Leaving now drains the audience task as well as connection and microphone tasks
before a replacement room connects.

`python3 tools/test_ios_voice_tasks.py` compiles the production Swift state machine
against deterministic SDK doubles on macOS. It verifies cancelled publication
without false failure and room replacement waiting for suspended audience work.
It uses no audio hardware and does not substitute for physical device acceptance.

## Foreground and battle transition recovery (2026-09-29)

VoiceService suspends token/join work while the app is backgrounded. The native
bridge suspends its audio engine and serializes foreground activation after old
room cleanup, preserving the user's Talk/Listen/Off choice. A transient native
capture failure with permission still granted now triggers connection recovery;
permission denial still falls back to Listen. Identical audience updates no
longer mute/reconfigure capture unnecessarily.

The root-owned MusicPlayer forwards application lifecycle notifications. On
foreground, MusicService recreates playback at the saved position, respecting
the current track, explicit stop and the music setting. It also reuses a player
that is awaiting deferred tree insertion instead of creating duplicates.

Validation: production Swift race/lifecycle tests pass; native arm64 framework
build succeeds; voice/music regression has 30 passing assertions. The broader
voice check has 410/412 passing assertions: the two remaining failures report
pre-existing Android and Windows binary/source hash mismatches. No physical
iPhone was available. These fixes require a new IPA; existing TestFlight
0.0.11 (24) does not contain them. Verify repeated prep/battle transitions and
background/foreground with three simultaneous speakers before accepting audio.
