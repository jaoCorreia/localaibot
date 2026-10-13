import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const HOME = process.env.LOCALBOT_HOME ?? join(homedir(), ".local-bot");

/**
 * One JSON file per collection under ~/.local-bot. Writes go through a temp
 * file + rename so a crash never leaves a half-written file. Swap for SQLite
 * once memory and history grow.
 */
export class Collection<T extends { id: string }> {
  private items: T[];
  private path: string;

  constructor(file: string, private mode = 0o644) {
    mkdirSync(HOME, { recursive: true });
    this.path = join(HOME, file);
    this.items = existsSync(this.path) ? JSON.parse(readFileSync(this.path, "utf8")) : [];
  }

  all(): T[] {
    return [...this.items];
  }

  get(id: string): T | undefined {
    return this.items.find((i) => i.id === id);
  }

  where(pred: (item: T) => boolean): T[] {
    return this.items.filter(pred);
  }

  upsert(item: T): T {
    const i = this.items.findIndex((x) => x.id === item.id);
    if (i >= 0) this.items[i] = item;
    else this.items.push(item);
    this.flush();
    return item;
  }

  remove(pred: (item: T) => boolean) {
    this.items = this.items.filter((i) => !pred(i));
    this.flush();
  }

  private flush() {
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.items, null, 2), { mode: this.mode });
    renameSync(tmp, this.path);
  }
}

/** Small JSON settings file (provider keys live here, so it is 0600). */
export class Settings<T extends object> {
  private path = join(HOME, "config.json");
  value: T;

  constructor(defaults: T) {
    mkdirSync(HOME, { recursive: true });
    const saved = existsSync(this.path) ? JSON.parse(readFileSync(this.path, "utf8")) : {};
    this.value = { ...defaults, ...saved };
  }

  update(patch: Partial<T>) {
    this.value = { ...this.value, ...patch };
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.value, null, 2), { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}
