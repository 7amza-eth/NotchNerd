// Types for `notch`, the API NotchNerd gives a notch mod: `window.notch` in the tab page and the
// global `notch` in the logic script (`main` in notch-mod.json).
// Keep in step with NotchNerd/Mods/NotchModAPI.swift.

type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

interface NotchInfo {
  /** The mod's id from notch-mod.json. */
  id: string;
  /** The mod's version from notch-mod.json. */
  version: string;
  /** NotchNerd's version, e.g. "0.4.0". */
  appVersion: string;
  /** True when loaded with "Load mod from folder…" (live reload, Web Inspector). */
  development: boolean;
  /** Where this code runs: the tab page or the logic script. */
  surface: 'page' | 'logic';
}

interface NotchStorage {
  /** The saved value, or null. */
  get<T extends JSONValue = JSONValue>(key: string): Promise<T | null>;
  /** Saves any JSON value. All of a mod's values together are limited to 1 MB. Fires "storage". */
  set(key: string, value: JSONValue): Promise<void>;
  remove(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

interface NotchChip {
  /** An SF Symbol name, drawn left of the notch. */
  icon?: string;
  /** Up to 24 characters, drawn right of the notch (width set by surfaces.closed.maxWidth). */
  text?: string;
  /** "green", "orange", "red", "blue", "purple", "yellow", "pink", "teal", "gray", "white" or "#RRGGBB". */
  tint?: string;
}

interface NotchNotice extends NotchChip {
  /** How long to show it: 2 to 8 seconds (default 4). */
  seconds?: number;
}

interface NotchMedia {
  playing: boolean;
  /** Nothing is loaded in any player. */
  idle: boolean;
  title: string;
  artist: string;
  album: string;
  /** Seconds. */
  duration: number;
  /** Seconds, as of this snapshot. */
  elapsed: number;
  /** The player's bundle id, e.g. "com.spotify.client". */
  app: string;
}

interface NotchCalendarEvent {
  id: string;
  title: string;
  /** ISO 8601. */
  start: string;
  end: string;
  allDay: boolean;
  location: string;
  calendar: string;
}

interface NotchAgent {
  working: number;
  live: number;
  needsYou: number;
  yourTurn: number;
  /** Titles and status only: no transcripts, prompts or paths. */
  sessions: { id: string; title: string; tool: string; phase: string; updated: string }[];
}

interface NotchNoteSummary {
  id: string;
  title: string;
  /** ISO 8601. */
  modified: string;
}

interface NotchEvents {
  /** No permission. Either side of this mod changed a storage key. */
  storage: { key: string };
  /** Needs "media.read". */
  media: NotchMedia;
  /** Needs "calendar.read". */
  calendar: NotchCalendarEvent[];
  /** Needs "agent.read". */
  agent: NotchAgent;
  /** Needs "notes.read". */
  notes: NotchNoteSummary[];
}

interface NotchLog {
  (...values: unknown[]): Promise<void>;
  /** Also shown under the mod in Settings → Mods. */
  error(...values: unknown[]): Promise<void>;
}

interface Notch {
  info(): Promise<NotchInfo>;
  /** Logs to Console.app (subsystem eth.7amza.notchnerd, category mod.<id>); in the page, also its console. */
  log: NotchLog;
  /**
   * Calls back with the current state right away, then on each change (at most once a second).
   * Returns a function that stops it.
   */
  on<E extends keyof NotchEvents>(event: E, callback: (payload: NotchEvents[E]) => void): () => void;
  /** This mod's saved data, shared by its page and its logic, kept across launches and updates. */
  storage: NotchStorage;
  /** The chip in the closed notch. Needs "surfaces": { "closed": {} }. */
  closed: {
    set(chip: NotchChip): Promise<void>;
    clear(): Promise<void>;
  };
  /**
   * Shows a message in the closed notch for a few seconds (2–8), over everything else, titled with the
   * mod's name. Needs "notify". At most one every 10 seconds, and none while the user has mod messages
   * turned off; resolves false when skipped.
   */
  notify(notice: NotchNotice): Promise<boolean>;
  /** Needs "media.read". */
  media: { get(): Promise<NotchMedia> };
  /** Needs "calendar.read". */
  calendar: { events(): Promise<NotchCalendarEvent[]> };
  /** Needs "agent.read". */
  agent: { get(): Promise<NotchAgent> };
  notes: {
    /** Needs "notes.read". */
    list(): Promise<NotchNoteSummary[]>;
    /** Needs "notes.read". */
    read(id: string): Promise<{ id: string; title: string; body: string } | null>;
    /** Needs "notes.write". Adds a line to the end of a note. */
    append(id: string, text: string): Promise<void>;
    /** Needs "notes.write". Makes a note without switching away from the open one; returns its id. */
    create(text: string, title?: string): Promise<string>;
  };
  /** Page only. Closes the notch. */
  close(): Promise<void>;
  /** Page only. Opens an http(s) link in the default browser. */
  openURL(url: string): Promise<void>;
}

declare const notch: Notch;
interface Window {
  readonly notch: Notch;
}
