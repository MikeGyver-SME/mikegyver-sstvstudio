# SSTV Studio — iOS app (v1.0.0)

A native iOS app that turns photos into SSTV sound and SSTV sound back
into photos — with **live listening from the microphone**, the thing the
web app can't do properly.

Bundle ID: `studio.mikegyver.sstvstudio` · iOS 17.0+ · SwiftUI · no server.

## The three tabs

- **Listen** — the headline. Tap Start Listening, hold the phone near a
  speaker or a radio playing SSTV. The app captures the mic, keeps a
  rolling 75-second buffer, and every 3 seconds tries to decode the last
  45 seconds. When it hears a full picture it shows it, with the mode and
  sync-pulse count, and offers Save to Photos / Share. A mic-level meter
  shows whether the audio is getting in. "Keep listening after a picture"
  stays on for the next image in a pass; off (default) it stops after the
  first picture so you don't get the same one twice.
- **Make** — pick a photo, choose Robot 36 (default) or Robot 72 and a fit
  (Contain / Cover / Stretch), tap Make the WAV. Play it straight to a
  radio mic, share the WAV, or tap "Decode it back" to check the file
  right here before it goes out.
- **Decode** — pick a WAV (or any audio file) from Files and decode the
  picture in it. Mode Auto / Robot 36 / Robot 72. Save to Photos / Share.

## How it works

The DSP is the same code as the SSTV Studio web app, verified end to end:
the encoder and decoder were cross-checked against the independent nSSTV
decoder, against a real Oct 23 ISS recording, and against the phone app's
own test screen. For iOS the core runs inside JavaScriptCore
(`SSTVStudio/sstv-core.js`, bundled as a resource) — Swift passes binary
data as base64 strings and gets base64 strings back, so no browser APIs
are involved. The mic audio is resampled to 8 kHz in Swift before it
reaches the decoder (SSTV tones live between 1200 and 2300 Hz, so 8 kHz
is plenty and keeps the bridge fast).

Files:

| File | What it does |
| --- | --- |
| `SSTVStudio/sstv-core.js` | The verified DSP core + iOS bridge (`iosEncode` / `iosDecode`). |
| `SSTVStudio/SSTVEngine.swift` | JavaScriptCore wrapper (one serial queue — JSContext is not thread-safe). |
| `SSTVStudio/ListenView.swift` | Live mic capture (AVAudioEngine), rolling buffer, periodic decode. |
| `SSTVStudio/MakeView.swift` | Photo picker, encode, WAV playback, decode-back check. |
| `SSTVStudio/DecodeView.swift` | Audio file picker, decode, save/share. |
| `SSTVStudio/WAVUtils.swift` | WAV write (16-bit PCM) and audio-file read (via AVAudioFile). |
| `SSTVStudio/ImageUtils.swift` | Fit a photo into the 320x240 frame, return RGBA pixels. |
| `SSTVStudio/ShareSheet.swift` | System share sheet. |
| `SSTVStudio/ContentView.swift` | The three-tab shell. |

## Building

1. Open `SSTVStudio.xcodeproj` in Xcode.
2. Select your development team under Signing & Capabilities (signing is
   Automatic; the bundle ID is already `studio.mikegyver.sstvstudio`).
3. Build and run on your iPhone (the mic needs a real device, not the
   simulator). For TestFlight, use your usual GitHub Actions pipeline.

No third-party dependencies, no network calls, no accounts.

## Testing the live listen

Play one of the test WAVs from the web app through a speaker and point
the phone at it:

- `sstv-test-robot36.wav` — clean Robot 36 test card (decodes in ~37 s).
- `sstv-colin-turkey-robot36.wav` — the Colin turkey (36 s).
- `sstv-real-iss-oct23.wav` — a real noisy ISS image (a harder test).

Hold the phone a foot or two from the speaker, volume up. The mic-level
meter should sit in the green. The picture appears a few seconds after
the tones finish.

## What I could not verify here

This was built on a Linux machine with no Xcode, so the project was
**not compiled** here. The DSP core was verified (Node round-trips at
44.1 kHz and 8 kHz, both modes, plus the bogus-mode fallback), the
project file is internally consistent (all 37 IDs resolve, braces
balanced), and the Swift files are balanced — but the first Xcode build
is the real test. If it throws a build error, paste it back and I'll fix
it the same turn.

## Changelog

- **v1.0.0** — First build. Listen / Make / Decode.
- **v1.0.1** (build 2) — Icon fix 1: generated all 9 AppIcon sizes and
  added `CFBundleIconName` (fixes altool 90713 / 90022).
- **v1.0.2** (build 3) — Icon fix 2: the 1024 icon moved to the
  `ios-marketing` slot and the `universal` (Any Appearance) slot (fixes
  altool 91111). Green on TestFlight.
- **v1.0.3** (build 4) — Screen-sleep fix. While listening, the app now
  keeps the screen awake (`isIdleTimerDisabled`), because auto-lock was
  suspending mic capture mid-picture — the decode came out half-done
  (good audio at the top, green static at the bottom). Also adds the
  `audio` background mode to Info.plist, so even if the screen does lock
  the mic keeps capturing and the picture appears when the phone wakes.
  After this fix you can hold the phone close to the speaker *and* keep
  the screen on — no more choosing between the two.
