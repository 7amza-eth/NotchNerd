// Types for `window.notch`, the API NotchNerd gives a notch mod's page.
// Keep in step with NotchNerd/Mods/NotchModBridge.swift.

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
}

interface NotchStorage {
  /** The saved value, or null. */
  get<T extends JSONValue = JSONValue>(key: string): Promise<T | null>;
  /** Saves any JSON value. All of a mod's values together are limited to 1 MB. */
  set(key: string, value: JSONValue): Promise<void>;
  remove(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

interface Notch {
  info(): Promise<NotchInfo>;
  /** Closes the notch. */
  close(): Promise<void>;
  /** Opens an http(s) link in the default browser. */
  openURL(url: string): Promise<void>;
  /** Logs to Console.app (subsystem eth.7amza.notchnerd, category mod.<id>) and the page console. */
  log(...values: unknown[]): Promise<void>;
  /** This mod's saved data, kept across launches and updates. */
  storage: NotchStorage;
}

declare const notch: Notch;
interface Window {
  readonly notch: Notch;
}
