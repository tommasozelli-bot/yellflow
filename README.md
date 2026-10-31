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

A quick double tap cancels the recording it just opened.

Click the menu-bar mic icon to switch **Language (Auto / EN / IT)** for dictation, browse
your **history** (what you dictated, what you copied), or quit. **Auto** detects the spoken
language from the audio; picking EN or IT just tells the model what to expect — mixed-in
words from the other language are still transcribed as heard.

## Two engines

The widget's **Engine** row picks the speech model. Both run on your Mac, offline.

- **Parakeet** (default) — Parakeet Ultra, run by [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp),
  the engine behind [Handy](https://github.com/cjpais/Handy). About ten times faster: on an
  M3, 15 s of speech in 0.25 s and 77 s in 1.7 s, ~250 MB of memory, ready in under a
  second. It writes its own punctuation. It can't take the vocabulary as a hint, so your
  names are fixed *after* transcription (see below).
- **Whisper** — `large-v3-turbo`. Slower (1–2 s per piece, more after an idle pause on an
  8 GB Mac), ~800 MB, but it reads your vocabulary *before* it decodes, so it is the
  safer pick when a dictation is full of names.

Switching unloads one model before loading the other, so they are never in memory together.

## History (never lose a dictation, never lose a copy)

The widget's **History** has two tabs:

- **Dictated**: every transcription, saved piece by piece *while you're still talking*,
  so not even a crash or a stolen focus can lose it.
- **Copied**: everything you copy, in any app (text, and file paths when you copy files).
  Passwords from password managers are skipped (they mark their copies as concealed).

Click any entry to copy it back to the clipboard. The list shows the latest 100; **Open all**
opens the whole history as a text file. Nothing is ever trimmed, everything stays local
(`~/Library/Application Support/YellFlow/history.json` and `clipboard.json`) and never
leaves your Mac.

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

With **Parakeet** the same terms are used afterwards: any run of words the model was
unsure about (low token probability) that *sounds like* a term — compared on an
Italian-ear phonetic key, so `gli El Flow` matches `Yell Flow` — is replaced by the term as
you wrote it. Exact matches only fix the spelling. Here size doesn't matter, so a
`## Solo Parakeet` heading starts a section Whisper skips: put there everything else you
say often. The names on the right of `corrections.txt` count as vocabulary too.

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

- 100% on-device (Parakeet Ultra Q8_0 ~740 MB through transcribe.cpp, or whisper.cpp
  with `large-v3-turbo` ~550 MB). Works with no internet.
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

# 2. build: compiles universal (arm64+x86_64), downloads the models
#    (Whisper ~547 MB, Parakeet ~740 MB checksum-verified, cached in
#    ~/.cache/yellflow), assembles "Yell Flow.app", installs it to
#    /Applications, and writes dist/Yell Flow.zip
#    (YELLFLOW_PARAKEET=0 or YELLFLOW_COREML=0 leave a model out)
bash build.sh
```

The whisper model is **not** committed — `build.sh` fetches
`ggml-large-v3-turbo-q5_0` from Hugging Face on first build. `whisper.cpp` ships in the
repo as the prebuilt `vendor/whisper.xcframework` (Metal-enabled, universal), and
transcribe.cpp as `vendor/transcribe/` (one universal `libtranscribe.dylib`, Metal on
Apple Silicon, ggml linked inside with only `transcribe_*` exported so it can't clash with
whisper's). `vendor/build-transcribe.sh` rebuilds it from a pinned commit; the app build
never compiles C++.

**Project layout:** `Sources/YellFlow/` — `AudioRecorder` (mic capture + live level),
`SpeechEngine` (the engine protocol, the shared Silero gate), `WhisperEngine` (whisper.cpp
wrapper, beam search, cheap language detection), `ParakeetEngine` (transcribe.cpp wrapper),
`SoundAlike` (vocabulary applied after Parakeet),
`AudioChunker` (cuts long takes at pauses), `DictationController` (gesture/state machine,
streaming pieces, warm-up), `RecordingIndicator` (waveform pill), `WidgetView` (menu-bar
popover + history), `Vocabulary`/`Corrections` (the context layer), `HistoryStore` +
`ClipboardHistory` (dictation and clipboard history), `WavWriter` (keeps the last recording for replays).

**Self-test / benchmark** (no permissions needed): `YellFlow --model M.bin --wav A.wav
[--lang auto|it|en]` transcribes a file twice and prints cold/warm timings. A `.gguf`
model runs Parakeet (`--model ".../Resources/parakeet-model.gguf"`), a `.bin` Whisper.
`YELLFLOW_BEAM=n` overrides the beam size for experiments.

## Credits & license

Speech recognition by [whisper.cpp](https://github.com/ggerganov/whisper.cpp),
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) and
[ggml](https://github.com/ggerganov/ggml) (MIT). The Parakeet Ultra model is by
[Moondream](https://huggingface.co/moondream/parakeet-ultra), refined from NVIDIA's
Parakeet TDT 0.6B v3, under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/);
the GGUF conversion is by [handy-computer](https://huggingface.co/handy-computer/parakeet-ultra-gguf). Yell Flow is released under the MIT
license — see [LICENSE](LICENSE).
