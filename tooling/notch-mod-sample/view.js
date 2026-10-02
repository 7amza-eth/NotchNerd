// Tally: the smallest useful notch mod. Shows the three things most mods need:
// reading and saving data (notch.storage), reacting to clicks, and info about where it runs.

const output = document.getElementById('count');
let count = 0;

function show() {
  output.textContent = String(count);
}

async function change(by) {
  count += by;
  show();
  await notch.storage.set('count', count);
}

document.getElementById('up').addEventListener('click', () => change(1));
document.getElementById('down').addEventListener('click', () => change(-1));
document.getElementById('reset').addEventListener('click', () => change(-count));

(async () => {
  count = (await notch.storage.get('count')) ?? 0;
  show();
  const info = await notch.info();
  document.getElementById('about').textContent =
    `${info.id} ${info.version}${info.development ? ' · developer' : ''}`;
})();
