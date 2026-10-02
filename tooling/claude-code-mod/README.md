# NotchNerd mod for Claude Code

Connects Claude Code sessions to [NotchNerd](https://github.com/7amza-eth/NotchNerd), the notch app for macOS.

- **Notepad tools.** Claude gets `notepad_list`, `notepad_read`, `notepad_append` and `notepad_new` over NotchNerd's always-open notepad, so it can read your scratch notes or leave you one.
- **`/notch [text]`** jots a line into the open note.
- **Reply from the notch.** With Settings → Agent → "Reply to sessions from the notch" on, what you type under a session in the notch is sent to it as your next prompt.

## Install

In NotchNerd, open **Settings → Mods** and click Install next to NotchNerd. Or:

```bash
claude plugin marketplace add mkbuilds4/mods
claude plugin install notchnerd@mkbuilds
```

Start a new chat to load it. It needs a Claude Code version with mods (function hooks).

## What it touches

Everything stays on your Mac; the mod makes no network requests.

- Reads `~/Library/Application Support/NotchNerd/Notepad/` (`index.json` and `notes/*.md`).
- Writes requests to `Notepad/inbox/`, which NotchNerd applies and deletes. It never writes your notes directly.
- For replies, writes a heartbeat to `Agent/mod-sessions/<session>.json` and reads replies from `Agent/outbox/<session>/`, deleting each one before submitting it.

If NotchNerd isn't running, notepad writes wait in the inbox until it starts.

## License

GPL v3 or later, like NotchNerd.
