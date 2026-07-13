# Yell Flow

Local, offline dictation for macOS. **Hold the Right Option (⌥) key, speak, release** —
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
- **Hold Right ⌥**, say your sentence, **release**.
- A yellow "REC" badge shows while you talk, then a spinner; the text appears a moment after
  you release.

**Read aloud** — select any text in any app:
- **Tap Right ⌥** (a quick press, don't hold) → Yell Flow reads the selection out loud.
- It detects the language automatically: Italian text gets an Italian voice, English an
  English one. Tap again to stop.

Click the menu-bar mic icon to switch **Language (Auto / EN / IT)** for dictation and the
**Voice (F / M)** for read-aloud, or to quit. **Auto** detects the spoken language from
the audio; picking EN or IT just tells the model what to expect — mixed-in words from
the other language are still transcribed as heard.

## Custom vocabulary (optional)

Yell Flow can be biased towards words it would otherwise mishear — names, brands,
technical jargon, English terms you drop into Italian sentences. On first dictation it
creates:

```
~/Library/Application Support/YellFlow/vocabulary.txt
```

Open it in any text editor and add **one word or phrase per line** (lines starting with
`#` are comments). Saved changes apply to the very next dictation — no restart needed.
The file is personal and lives outside the app and outside this repository.

## Notes

- 100% on-device (whisper.cpp, `large-v3-turbo` quantized model, ~550 MB). Works with
  no internet.
- Your clipboard is never touched — text is typed directly at the cursor.
- Apple Silicon recommended; also runs on Intel Macs.
