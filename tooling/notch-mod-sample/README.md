# Tally: a sample notch mod

A notch mod changes NotchNerd's notch. It can have two parts, and NotchNerd runs both in a sandbox:

- **A tab**: a small web page (HTML, JS, CSS) shown as a tab in the open notch. It runs only while the tab is on screen.
- **Logic**: one plain JavaScript file that runs the whole time the mod is on, even with the notch closed. It can show a **chip** in the closed notch and **notifications**, and react to what's playing, your calendar, your Claude Code sessions and your notepad, if the mod has permission.

Tally has both. Its tab counts up and down; its logic shows the count in the closed notch. Start a new mod by copying this folder.

## Try it

1. In NotchNerd, open **Settings → Mods → Add a mod**, paste `https://github.com/7amza-eth/NotchNerd/tree/main/tooling/notch-mod-sample` and click **Add**. Tally installs and turns on, and a **Tally** tab appears in the notch. (Share your own mod the same way: push it to GitHub and pass on the link. Adding the link again updates it.)
2. To work on it, use **Settings → Mods → Notch mods → Load mod from folder…** and choose this folder instead. A folder wins over an installed copy with the same id.
3. Tap **+** a few times and close the notch: the count shows beside it.
4. Edit any file. The mod reloads on its own, tab and logic.
5. Debugging: the tab page opens in Safari → **Develop** → NotchNerd → *Tally* (turn on Safari → Settings → Advanced → "Show features for web developers" first). Logic errors show under the mod in Settings, and `notch.log` goes to Console.app (category `mod.tally`).

## Files

| File | What it is |
| --- | --- |
| `notch-mod.json` | The manifest: id, name, version, what the mod adds to the notch, and its permissions. |
| `view.html`, `view.js`, `styles.css` | The tab's page. Scripts and styles must be separate files. |
| `main.js` | The logic. |
| `notchnerd.d.ts` | Types for `notch`, for editor completion. |

## The manifest

```json
{
  "id": "tally",
  "name": "Tally",
  "version": "1.1.0",
  "minAppVersion": "0.3.5",
  "author": "MK Builds",
  "description": "A sample notch mod.",
  "main": "main.js",
  "surfaces": {
    "tab": { "title": "Tally", "icon": "plusminus.circle", "height": 170, "keyboard": false, "view": "view.html" },
    "closed": { "maxWidth": 40 }
  },
  "permissions": ["media.read", "notify", "network:api.example.com"]
}
```

- `id`: lowercase words joined by hyphens. Must match your entry in the mod directory.
- `main`: the logic file. Leave it out for a tab-only mod.
- `surfaces.tab`: leave it out for a mod without a tab. `icon` is any [SF Symbol](https://developer.apple.com/sf-symbols/) name; `height` is 120 to 320 points; set `keyboard` to `true` if the tab has text fields.
- `surfaces.closed`: lets the mod show a chip in the closed notch. `maxWidth` is the width of its text, 30 to 120 points.
- `permissions`:

| Permission | Lets the mod |
| --- | --- |
| `media.read` | See what's playing (`notch.media`, the `media` event). |
| `calendar.read` | See calendar events (`notch.calendar`, `calendar`). |
| `agent.read` | See Claude Code sessions: counts, titles and status, never transcripts (`notch.agent`, `agent`). |
| `notes.read` | List and read notepad notes (`notch.notes.list/read`, `notes`). |
| `notes.write` | Add to notes or make new ones (`notch.notes.append/create`). |
| `notify` | Show a notification in the notch (`notch.notify`). |
| `network:<host>` | Reach that host over https from the tab page. `*.example.com` covers subdomains. |

## The closed notch

The chip is a symbol on the left of the notch and a few words on the right, drawn by NotchNerd in its own style. It gives way to the things that matter more: a Claude session that needs you, battery and volume, music, and Claude working. It shows over Claude's calm "active" indicator. A **notification** (`notch.notify`) is different: it shows for a few seconds over everything in the closed notch, titled with your mod's name, in the same style as Claude Code mods' messages. At most one every 10 seconds per mod, and none if the user turned off "Let mods show messages in the notch". If more than one mod has a chip, the user picks which shows in Settings.

## The sandbox

- **Tab page:** loads only its own files. No inline `<script>`, but inline styles are fine. No network except declared hosts. Clicked web links open in the browser. Cookies and `localStorage` don't last; use `notch.storage`.
- **Logic:** plain JavaScript, with no DOM, no `fetch` and no modules. It gets `notch`, `setTimeout`/`setInterval` (intervals at least one second apart, at most 100 timers) and `console`. A single run that takes over 2 seconds stops the mod; it shows as stopped in Settings until you fix it.
- **Nothing else:** no files outside the mod's folder, no shell, no native code.

## The API

The full list is in `notchnerd.d.ts`. Everything returns a promise.

```js
await notch.storage.set('count', 3);          // any JSON, 1 MB per mod, shared by tab and logic
const count = await notch.storage.get('count');

notch.closed.set({ icon: 'timer', text: '24:59', tint: 'orange' });
notch.notify({ icon: 'bell', text: 'Break time', seconds: 5 });   // needs "notify"

const off = notch.on('media', (media) => {     // needs "media.read"; fires now, then on change
  notch.closed.set({ icon: media.playing ? 'play.fill' : 'pause.fill', text: media.artist });
});
off();                                          // stop listening

notch.log('hello');                             // Console.app, category mod.<id>
notch.log.error(new Error('oops'));             // also shown in Settings
```

From the tab page only: `notch.close()` and `notch.openURL(url)`.
