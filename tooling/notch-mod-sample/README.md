# Tally: a sample notch mod

A notch mod adds a tab to NotchNerd's notch. It's a small web page that NotchNerd runs in a sandbox. Start a new mod by copying this folder.

## Try it

1. In NotchNerd, open **Settings → Mods → Notch mods** and click **Load mod from folder…**.
2. Choose this folder. Tally is turned on and a **Tally** tab appears in the notch.
3. Edit `view.js` or `styles.css`. While the tab is open it reloads on its own.
4. To debug, open Safari → **Develop** → NotchNerd → *Tally* for the Web Inspector. (Turn on Safari → Settings → Advanced → "Show features for web developers" first.)

## Files

| File | What it is |
| --- | --- |
| `notch-mod.json` | The manifest: id, name, version, what it adds to the notch, and its permissions. |
| `view.html` | The tab's page. Link your scripts and styles as separate files. |
| `view.js`, `styles.css` | The page's script and style. Name them anything. |
| `notchnerd.d.ts` | Types for `window.notch`, for editor completion. |

## The manifest

```json
{
  "id": "tally",
  "name": "Tally",
  "version": "1.0.0",
  "minAppVersion": "0.3.4",
  "author": "MK Builds",
  "description": "A sample notch mod.",
  "surfaces": {
    "tab": { "title": "Tally", "icon": "plusminus.circle", "height": 170, "keyboard": false, "view": "view.html" }
  },
  "permissions": ["storage", "network:api.example.com"]
}
```

- `id`: lowercase words joined by hyphens. Must match your entry in the mod directory.
- `surfaces.tab.icon`: any [SF Symbol](https://developer.apple.com/sf-symbols/) name.
- `surfaces.tab.height`: 120 to 320 points.
- `surfaces.tab.keyboard`: set `true` if the tab has text fields. The notch then takes key focus and stays open while the tab shows.
- `permissions`: `network:<host>` lets the page reach that host over https; `*.example.com` covers subdomains. Nothing else on the network is reachable.

## The sandbox

- The page loads only its own files. No inline `<script>`: put scripts in files. Inline styles are fine.
- No network except the hosts you declare. No access to your Mac's files.
- Web links the user clicks open in their browser. `notch.openURL(url)` does the same from code.
- Cookies and `localStorage` don't survive. Use `notch.storage` to keep data.
- The page exists only while its tab is on screen; NotchNerd closes it when the notch closes. Save anything you need with `notch.storage`.

## The API

See `notchnerd.d.ts`. In short:

```js
const info = await notch.info();               // { id, version, appVersion, development }
await notch.storage.set('count', 3);           // any JSON value, up to 1 MB per mod
const count = await notch.storage.get('count');
notch.openURL('https://example.com');
notch.close();
notch.log('hello');                            // Console.app, category mod.<id>
```

More is coming: a chip in the closed notch, notifications, and read access to now playing, calendar and Claude Code sessions, each behind a permission.
