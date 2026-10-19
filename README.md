# Yell Flow

Local, offline dictation for macOS. **Tap the Right Option (⌥) key, speak, tap again** —
your words get typed wherever your cursor is, in any app. Nothing leaves your Mac.

---

## Install

1. Unzip and drag **Yell Flow.app** into your **Applications** folder.
2. **First launch:** right-click the app → **Open** → **Open** again.
   (Yell Flow isn't signed by a paid Apple developer account, so macOS asks once.)
   - On newer macOS, if right-click → Open doesn't offer the button: try to open the app
     normally, then go to **System Settings → Privacy & Security**, scroll down and click
     **"Open Anyway"** next to Yell Flow.
   - Terminal alternative: `xattr -dr com.apple.quarantine "/Applications/Yell Flow.app"`.
3. A **microphone icon** (a mic in a circle) appears in your menu bar, top-right. That's the whole
   app — there is no window and no Dock icon. Click that icon to open the little widget.

## Grant 3 permissions (one time)

Yell Flow needs these to hear you and type for you. Click the menu-bar icon — if any are
missing it shows a button that opens the right settings pane. Or do it manually in
**System Settings → Privacy & Security**:

| Permission | Why | Where |
|---|---|---|
| **Microphone** | to hear your voice | Privacy & Security → Microphone |
| **Accessibility** | to paste text into other apps | Privacy & Security → Accessibility |
| **Input Monitoring** | for the global Right ⌥ shortcut | Privacy & Security → Input Monitoring |

Toggle **Yell Flow** on in each list. You may need to quit and reopen the app once after granting.

## Use it

**Dictate** — put your cursor anywhere you can type (Notes, Mail, Slack, a browser field…):
- **Tap Right ⌥** once → recording starts (yellow "REC" badge on screen).
- Say what you want, then **tap Right ⌥ again** → recording stops, a spinner shows while
  it transcribes, and the text appears at your cursor.

While recording, a floating **pill with a live waveform** appears at the bottom of the
screen (visible even over full-screen apps), so you always know it's listening.

**Read aloud** — select any text in any app:
- **Double-tap Right ⌥** (two quick taps) → Yell Flow reads the selection out loud.
- It detects the language automatically: Italian text gets an Italian voice, English an
  English one. A single tap while it speaks stops it.

Click the menu-bar mic icon to switch **Language (Auto / EN / IT)** for dictation and the
**Voice (F / M)** for read-aloud, see your **history**, or quit. **Auto** detects the spoken
language from the audio; picking EN or IT just tells the model what to expect — mixed-in
words from the other language are still transcribed as heard.

## History (never lose a dictation)

Every transcription is saved locally. Sometimes the focus is stolen (a desktop click, a
slow app) and the typed text doesn't land where you wanted — open the menu-bar widget and
you'll find your recent dictations under **History**. Click any entry to copy it back to
the clipboard. History is local only, capped to the most recent entries, and never leaves
your Mac.

## Personalizing accuracy — the two context files (important)

Because Yell Flow runs **entirely offline**, its accuracy on *your* words — names, brands,
jargon, English terms inside Italian — depends on two plain-text files you control. Both
live next to the app's data and **hot-reload**: edit, save, and the very next dictation
uses them. No restart.

```
~/Library/Application Support/YellFlow/vocabulary.txt    # soft phonetic bias
~/Library/Application Support/YellFlow/corrections.txt   # guaranteed fixes
```

**`vocabulary.txt`** — one word/phrase per line. These *nudge* the model to "hear" a term
it might otherwise miss (e.g. a surname, a product name). It's only a hint, and it must
stay **short** — Whisper only keeps ~224 tokens of it, so list a handful of genuinely
tricky words, not everything.

**`corrections.txt`** — one rule per line as `wrong => right`. Applied **after**
transcription, so it's deterministic and **unlimited**: whatever the model writes, these
rules rewrite it. This is where recurring names belong — the guaranteed way to make them
always come out right. Example:

```
git hub => GitHub
push a request => pull request
back end => backend
```

Rule of thumb: put a few hard-to-hear words in `vocabulary.txt`; put every name that
*must* be spelled correctly in `corrections.txt`. Both files are created (commented, with
examples) on first run, are personal, and are **not** part of this repository.

Corrections never touch email addresses or domain names (`acme` won't rewrite
`you@acme.com`).

**Replaying a misheard word.** The audio of your **last dictation** is kept as
`~/Library/Application Support/YellFlow/last-recording.wav` (overwritten every time,
never leaves your Mac). If a word came out wrong you can run it through the engine again
after adding a rule or a term:

```bash
"/Applications/Yell Flow.app/Contents/MacOS/YellFlow" \
  --model "/Applications/Yell Flow.app/Contents/Resources/whisper-model.bin" \
  --wav ~/Library/Application\ Support/YellFlow/last-recording.wav --lang auto
```

## How it stays fast

Whisper's cost is per 30-second window and the model on an 8 GB Mac gets paged out
after a few idle minutes (that alone used to add 4–6 s to the next dictation). Yell Flow
hides all of that behind the recording itself:

- **Warm-up while you talk** — if the engine has been idle, it's woken up the moment you
  tap REC, not when you tap stop.
- **Pieces while you talk** — long dictations are cut at your pauses (never mid-word)
  into ≤ 28 s pieces, and each piece is transcribed while you keep talking. At the final
  tap only the tail is left: roughly one window (~1.5 s) whatever the length.
- **Language detection in the background** — in Auto mode the language is detected on
  the first 8 s of speech during the recording; very short dictations reuse the last
  detected language. (A wrong hint doesn't hurt: `large-v3-turbo` follows the audio.)

## Notes

- 100% on-device (whisper.cpp, `large-v3-turbo` quantized model, ~550 MB). Works with
  no internet.
- Text is pasted at the cursor (⌘V). Your clipboard is put back 1.5 s later, unless you
  copied something else in the meantime, and the dictation is marked transient so
  clipboard managers don't record it.
- A Silero voice-activity detector (~1 MB, bundled) skips pieces with no speech, so
  silence never turns into invented text ("Thank you.", "Grazie.").
- Apple Silicon recommended; also runs on Intel Macs.

---

## Build from source

No Xcode required — Command Line Tools only. The app bundle is assembled by hand.

**Requirements:** macOS 13.3+, Xcode Command Line Tools (`xcode-select --install`).

```bash
# 1. (once) create a stable local signing identity so macOS permission grants
#    survive rebuilds — otherwise you'd re-grant Mic/Accessibility every build.
bash setup-signing.sh

# 2. build: compiles universal (arm64+x86_64), downloads the whisper model
#    (~547 MB, cached in ~/.cache/yellflow), assembles "Yell Flow.app",
#    installs it to /Applications, and writes dist/Yell Flow.zip
bash build.sh
```

The whisper model is **not** committed — `build.sh` fetches
`ggml-large-v3-turbo-q5_0` from Hugging Face on first build. `whisper.cpp` ships in the
repo as the prebuilt `vendor/whisper.xcframework` (Metal-enabled, universal).

**Project layout:** `Sources/YellFlow/` — `AudioRecorder` (mic capture + live level),
`WhisperEngine` (whisper.cpp wrapper, beam search, cheap language detection),
`AudioChunker` (cuts long takes at pauses), `DictationController` (gesture/state machine,
streaming pieces, warm-up), `RecordingIndicator` (waveform pill), `WidgetView` (menu-bar
popover + history), `Vocabulary`/`Corrections`/`TranscriptStore` (the context and history
layers), `WavWriter` (keeps the last recording for replays).

**Self-test / benchmark** (no permissions needed): `YellFlow --model M.bin --wav A.wav
[--lang auto|it|en]` transcribes a file twice and prints cold/warm timings.
`YELLFLOW_BEAM=n` overrides the beam size for experiments.

## Credits & license

Speech recognition by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and
[ggml](https://github.com/ggerganov/ggml) (MIT). Yell Flow is released under the MIT
license — see [LICENSE](LICENSE).
