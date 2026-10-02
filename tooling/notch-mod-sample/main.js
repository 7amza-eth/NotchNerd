// Tally's logic: runs while the mod is on, even with the notch closed. No page, no DOM; just `notch`,
// timers and console. It keeps the closed-notch chip in step with the count the tab page saves.

async function showCount() {
  const count = (await notch.storage.get('count')) ?? 0;
  if (count === 0) {
    await notch.closed.clear();
  } else {
    await notch.closed.set({ icon: 'plusminus.circle', text: String(count), tint: count > 0 ? 'green' : 'orange' });
  }
}

// The tab page and this script share storage; "storage" fires whenever either side changes a key.
notch.on('storage', ({ key }) => {
  if (key === 'count') showCount();
});

showCount();
