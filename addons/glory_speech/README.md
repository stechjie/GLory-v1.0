# Windows offline speech

`SpeechToText.gd` routes Windows recordings to `WindowsSpeechToText.gd`.
The bundled whisper.cpp CPU CLI recognizes the already captured 16 kHz mono WAV
without opening a second microphone or uploading audio. Language is detected
automatically; the multilingual quantized base model supports Chinese/English.
Recognition runs in a hidden child process with at most four CPU threads.
Closing the composer cancels the job. Timeout is 90 seconds; temporary audio and
transcripts are deleted. Recognized text is an editable draft, never auto-sent.

The fixed runtime and model are versioned with the source through an exact
19-file whitelist. A normal Git checkout is ready to use; no separate download
or Git LFS installation is needed. To repair missing files, run:

```powershell
./tools/setup_windows_speech.ps1
# Optional proxy:
./tools/setup_windows_speech.ps1 -ProxyUrl http://127.0.0.1:12450
```

`runtime.json` pins the upstream CPU release, immutable model revision, download
SHA-256 digests and individual shipped files. Inputs live in `bin/windows`
(about 69 MiB total). Only the pinned manifest files are whitelisted; unrelated
build outputs remain ignored. Models are never downloaded at player runtime.
When upgrading, update the manifest, whitelist and binaries together.
The existing Microsoft runtime DLLs are copied from the desktop voice plugin.
Whisper/model MIT licenses are included beside the executable.

The enabled export plugin copies the files to `speech/` beside Windows x86_64
executables, outside PCK. Mobile exports do not include them. Running from the
editor uses `bin/windows`; exported games use their adjacent `speech` directory.
Distribute that directory with the executable. Missing inputs cause export errors.
Windows ARM64 and 32-bit exports are not supported by this CPU runtime.

Verification from the repository root (requires installed Chinese/English Windows
TTS voices for synthetic fixtures; these are not recognition dependencies):

```powershell
./tools/make_windows_speech_fixtures.ps1
Godot_console.exe --headless --path . res://tools/windows_speech_check.tscn -- --no-account
```

This checks actual offline Chinese/English inference, pre-launch and running-job
cancellation, silence filtering and temporary-file cleanup. Real microphone noise,
accents and low-spec computers still require separate testing.

Upstream: <https://github.com/ggml-org/whisper.cpp/releases/tag/b5454>
Model: <https://huggingface.co/ggerganov/whisper.cpp>
