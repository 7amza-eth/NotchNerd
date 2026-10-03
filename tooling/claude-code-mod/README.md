# NotchNerd mod for Claude Code

Connects Claude Code sessions to [NotchNerd](https://github.com/7amza-eth/NotchNerd), the notch app for macOS.

- **Notepad tools.** Claude gets `notepad_list`, `notepad_read`, `notepad_append` and `notepad_new` over NotchNerd's always-open notepad, so it can read your scratch notes or leave you one.
- **Notch messages.** Claude gets `notch_notify`, which flashes a short message in the closed notch: a deploy going live, tests failing, something waiting on you. Turn these off in NotchNerd under Settings → Mods.
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

- For notch messages, writes a request to `Events/inbox/`, which NotchNerd shows and deletes.

If NotchNerd isn't running, notepad writes wait in the inbox until it starts. Notch messages older than a minute are dropped instead of shown late.

## Show messages in the notch from your own mod

Any mod (or script) can use NotchNerd's event inbox. Write one JSON file per message to `~/Library/Application Support/NotchNerd/Events/inbox/<ms>-<random>.json`:

```json
{ "version": 1, "type": "toast", "message": "Deploy is live", "title": "deploy-watch",
  "style": "success", "createdAt": 1759450000000 }
```

`message` is required. Optional: `title` (short source label, default "Claude Code"), `style` (`info`, `success`, `warning` or `error`), `icon` (an SF Symbol name), `duration` (2 to 10 seconds, default 4), `sound` (true plays the notification sound) and `createdAt` (milliseconds since the epoch; messages more than a minute old are dropped). NotchNerd deletes the file once it has read it.

## License

GPL v3 or later, like NotchNerd.
