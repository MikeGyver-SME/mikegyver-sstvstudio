# SSTV Studio — iOS app (v1.0.5, build 6)

A native iOS app that turns photos into SSTV sound and SSTV sound back
into photos — with **live listening from the microphone**, the thing the
web app can't do properly.

Bundle ID: `studio.mikegyver.sstvstudio` · iOS 17.0+ · SwiftUI · no server.

## The five tabs

- **Listen** — the headline. Tap Start Listening, hold the phone near a
  speaker or a radio playing SSTV. The app captures the mic, keeps a
  rolling 75-second buffer, and every 3 seconds tries to decode the last
  45 seconds. When it hears a full picture it shows it, with the mode and
  sync-pulse count, and offers Save to Photos / Share. A mic-level meter
  shows whether the audio is getting in, and a live waterfall shows the
  SSTV tones sweeping across 1200-2300 Hz, so you can see in the first
  few seconds whether the signal is really there. "Keep listening after
  a picture" stays on for the next image in a pass; off (default) it
  stops after the first picture so you don't get the same one twice.
  Every listening session is also recorded to a WAV file (see below), and
  every decoded picture is auto-saved to the Gallery and Photos.
- **Make** — pick a photo, choose Robot 36 (default) or Robot 72 and a fit
  (Contain / Cover / Stretch), tap Make the WAV. Play it straight to a
  radio mic, share the WAV, or tap "Decode it back" to check the file
  right here before it goes out. Also: Formula mode (type a formula, it
  is rendered large as the picture), Puzzle mode (a generated puzzle),
  and an optional Secret Note (see below).
- **Decode** — pick a WAV (or any audio file) from Files and decode the
  picture in it. Mode Auto / Robot 36 / Robot 72. Save to Photos / Share.
  If the file carries a secret note, the tab asks for the passphrase.
- **Gallery** — every picture the app decodes, newest first. Pictures are
  auto-saved here the moment they decode (Listen, Make decode-back, and
  Decode all feed it), with the date, mode, source, and frequency. Tap a
  picture for the full view, Share, Save to Photos again, or Delete.
  Pictures survive the app closing and the screen locking.
- **Codebook** — the Windtalkers-style game. Words become pictures; only
  someone with the same book can turn them back into words. See below.

## New in v1.0.5 — Secret Note, Codebook, Math Puzzle

**File-only vs on-air — read this first.** FCC Part 97 prohibits
transmitting messages encoded to obscure their meaning over amateur
radio. Secret Note and Codebook are FILE / IN-PERSON ONLY: share the
WAV or PNG file itself, never play a secret-carrying WAV into a radio
mic. The app shows that warning wherever they are used. Math Puzzle is
the only one of the three that is legal on air, because nothing is
hidden — the picture IS the message.

- **Secret Note** (`SecretNote.swift`). In Make, turn on "Secret Note
  (file only)", type a passphrase and a note (max 200 chars). The note
  is encrypted and embedded in the generated WAV file; the picture gets
  a small lock badge in the corner so the recipient knows a note is
  present. In Decode, a file with a note asks for the passphrase —
  wrong passphrase shows "Wrong passphrase", never partial text. A
  Gallery picture made by Make decode-back can also be unlocked in the
  Gallery detail view (the Photos copy loses the note when iOS
  re-encodes it; the Gallery file on disk is the record).
  - Crypto: AES-256-GCM (CryptoKit), key from PBKDF2-HMAC-SHA256,
    100,000 iterations, random 16-byte salt, 32-byte key; random
    12-byte nonce. Envelope JSON
    `{"v":1,"salt":base64,"data":base64}` where data is the sealed-box
    combined form (nonce || ciphertext || tag).
  - Carrier: the envelope rides in the WAV file as a trailing RIFF
    chunk "SSTV" holding an "SSTVNOTE" trailer (magic + length +
    envelope). The audio itself is untouched.
  - Honest limitation: pixel-LSB hiding does NOT survive SSTV
    encoding, let alone a speaker-to-mic path — so it is not used.
    A live radio decode cannot carry a note. File to file only.
- **Codebook** (`CodebookStore.swift`, `CodebookView.swift`, new tab).
  A starter book of 20 entries (word -> symbol). Send: type a phrase,
  the app builds a 320x240 collage of the pictures in order (up to 12
  words) and makes a Robot 36 WAV from it. Read: pick the collage
  picture, then tap the matching entries in order — the human matches
  the pictures, the app turns them back into words. Book: add / delete
  entries, attach a photo to an entry (that photo stays on this phone
  only), share the book as a JSON file, import a shared book, reset to
  the starter book. Symbols travel with a shared book; photos do not.
- **Math Puzzle** (`MathPuzzle.swift`). In Make, Formula mode renders
  any typed formula large and high-contrast as a 320x240 picture
  (presets: E=mc^2, area of a circle, Pythagoras, v=d/t, F=ma).
  Puzzle mode generates a random puzzle — multiplication, subtraction,
  one-step algebra, or circle area — and shows the answer only to the
  sender. The recipient sees only the question and solves it.

## New in v1.0.4 — the Saturday features

- **Gallery + auto-save** (`GalleryStore.swift`, `GalleryView.swift`).
  Every decoded picture is written to `Documents/Gallery/<id>.png` with
  a `Documents/Gallery/gallery.json` metadata record (date/time, mode
  Robot 36/72, source Listen/Make/Decode, frequency 437.550 MHz for live
  Listen decodes), and a copy is saved to Photos automatically. No more
  "tap Save or lose it".
- **Pass audio recording** (`PassRecorder.swift`). While listening, the
  same mic stream that feeds the decoder is recorded to
  `Documents/Recordings/sstv-pass-<yyyy-MM-dd-HHmm>.wav` — 8 kHz mono,
  16-bit PCM, about 9.6 MB for a 10-minute pass. It keeps recording in
  the background (the `audio` background mode is already set) and stops
  cleanly on Stop Listening. After stopping, the Listen tab shows the
  saved recording with a Share option, so you can open it in the Decode
  tab later and re-decode a pass whose live decode glitched.
- **Live waterfall** (`WaterfallView.swift`). A scrolling spectrogram of
  1200-2300 Hz, computed in Swift with a Goertzel filter bank (48 bins)
  at about 10 columns a second, on a background queue so it cannot
  starve the decoder. Frequency markers at 1200 / 1500 / 1900 / 2300 Hz.
  Bright = tone present. The mic-level meter is unchanged.

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
| `SSTVStudio/ListenView.swift` | Live mic capture (AVAudioEngine), rolling buffer, periodic decode, waterfall feed, pass recording, auto-save. |
| `SSTVStudio/GalleryStore.swift` | Gallery model + auto-save store (Documents/Gallery, gallery.json, Photos copy). |
| `SSTVStudio/GalleryView.swift` | Gallery tab: grid, full view, Share / Save / Delete. |
| `SSTVStudio/PassRecorder.swift` | Whole-session mic recording to 8 kHz mono WAV (Documents/Recordings). |
| `SSTVStudio/WaterfallView.swift` | Live 1200-2300 Hz spectrogram (Goertzel bank, ~10 fps, background queue). |
| `SSTVStudio/MakeView.swift` | Photo picker, encode, WAV playback, decode-back check, Formula / Puzzle modes, Secret Note. |
| `SSTVStudio/DecodeView.swift` | Audio file picker, decode, save/share, Secret Note unlock. |
| `SSTVStudio/SecretNote.swift` | AES-256-GCM note crypto (PBKDF2-HMAC-SHA256), WAV/PNG trailer embed + extract, lock badge. |
| `SSTVStudio/CodebookStore.swift` | Codebook model + store (starter book, JSON share/import, collage renderer). |
| `SSTVStudio/CodebookView.swift` | Codebook tab: Send / Read / Book. |
| `SSTVStudio/MathPuzzle.swift` | Formula rendering + puzzle generators + presets. |
| `SSTVStudio/WAVUtils.swift` | WAV write (16-bit PCM, optional secret chunk) and audio-file read (via AVAudioFile). |
| `SSTVStudio/ImageUtils.swift` | Fit a photo into the 320x240 frame, return RGBA pixels. |
| `SSTVStudio/ShareSheet.swift` | System share sheet. |
| `SSTVStudio/ContentView.swift` | The five-tab shell. |

## Building

1. Open `SSTVStudio.xcodeproj` in Xcode.
2. Select your development team under Signing & Capabilities (signing is
   Automatic; the bundle ID is already `studio.mikegyver.sstvstudio`).
3. Build and run on your iPhone (the mic needs a real device, not the
   simulator). For TestFlight, use your usual GitHub Actions pipeline.

No third-party dependencies, no network calls, no accounts.

## Testing the new features (v1.0.5)

- **Secret Note:** Make tab, turn on Secret Note, passphrase + note,
  make the WAV, share the WAV file to Files, open it in the Decode
  tab — it should ask for the passphrase, show the note with the right
  one, and say "Wrong passphrase" with a wrong one. The picture should
  show the lock badge. Play the same WAV through a speaker and decode
  it live: the picture arrives, the note does NOT — that is expected,
  the note lives in the file, not the tones.
- **Codebook:** Codebook tab, Send "hello friend", build the collage,
  make the WAV. Read: pick the collage picture, tap the matching
  entries in order — the phrase should come back. Share the book,
  import it back, and check the entries survive.
- **Math Puzzle:** Make tab, Formula, pick a preset, make the WAV,
  decode it back — the formula should be big and readable. Puzzle,
  "New Puzzle" — the answer is shown only to the sender.
- **Gallery:** decode any picture (Listen, Make decode-back, or Decode),
  then open the Gallery tab — it should already be there, newest first,
  and still be there after force-quitting and reopening the app.

## Testing the v1.0.4 features (still in this build)

- **Recording:** tap Start Listening, let it run a minute, tap Stop.
  The Listen tab should show `sstv-pass-<date>-<time>.wav` with a Share
  button. Share it to Files, then open it in the Decode tab — it should
  decode the same picture back.
- **Waterfall:** play an SSTV WAV through a speaker. Bright diagonal
  bands should sweep across the waterfall while the tones play, and the
  1200 / 1500 / 1900 / 2300 Hz markers should line up with the band
  edges. The decode should still land on time — if pictures start
  arriving late or not at all, the waterfall is costing too much CPU.

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
project file is internally consistent (all 53 IDs resolve, braces
balanced), and the Swift files are balanced — but the GitHub Actions
build is the real compile test. v1.0.4 (build 5) was green on TestFlight;
v1.0.5 adds four new Swift files and four edited views, so if the
Actions build throws a build error, paste it back and I'll fix it the
same turn.

## Changelog

- **v1.0.0** — First build. Listen / Make / Decode.
- **v1.0.1** (build 2) — Icon fix 1: generated all 9 AppIcon sizes and
  added `CFBundleIconName` (fixes altool 90713 / 90022).
- **v1.0.2** (build 3) — Icon fix 2: the 1024 icon moved to the
  `ios-marketing` slot and the `universal` (Any Appearance) slot (fixes
  altool 91111). Green on TestFlight.
- **v1.0.5** (build 6) — Secret Note (AES-256-GCM, file-only, in the
  WAV file — pixel-LSB hiding was NOT used, it does not survive SSTV),
  Codebook tab (Windtalkers-style, file/in-person only), Math Puzzle
  mode (legal on air). Marketing version stays 1.0; tag v1.0.5, build 6.
  Push with
  `powershell -ExecutionPolicy Bypass -File .\scripts\push-sstvstudio.ps1`
  (defaults now point at `sstv-studio-ios-v1.0.5` and tag v1.0.5).
- **v1.0.4** (build 5) — Saturday features: Gallery + auto-save, pass
  audio recording (8 kHz mono WAV), and the live 1200-2300 Hz waterfall.
  Marketing version stays 1.0; tag v1.0.4, build 5. Push with
  `powershell -ExecutionPolicy Bypass -File .\scripts\push-sstvstudio.ps1`
  (defaults now point at `sstv-studio-ios-v1.0.4` and tag v1.0.4).
- **v1.0.3** (build 4) — Screen-sleep fix. While listening, the app now
  keeps the screen awake (`isIdleTimerDisabled`), because auto-lock was
  suspending mic capture mid-picture — the decode came out half-done
  (good audio at the top, green static at the bottom). Also adds the
  `audio` background mode to Info.plist, so even if the screen does lock
  the mic keeps capturing and the picture appears when the phone wakes.
  After this fix you can hold the phone close to the speaker *and* keep
  the screen on — no more choosing between the two.
