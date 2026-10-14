import { execFile, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { platform } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { HOME } from "./store.ts";

const run = promisify(execFile);

/**
 * Where API keys live. On macOS: the login Keychain (via Apple's `security`
 * tool, so no native module and no prompts across rebuilds). Elsewhere: a
 * 0600 file until the Windows/Linux shells bring their own credential store.
 * Reads are served from memory after `load`.
 */
interface Backend {
  get(account: string): Promise<string | undefined>;
  set(account: string, value: string): Promise<void>;
  delete(account: string): Promise<void>;
  readonly label: string;
}

const SERVICE = "Local Bot";

class MacKeychain implements Backend {
  readonly label = "Keychain";

  async get(account: string) {
    try {
      const { stdout } = await run("security", ["find-generic-password", "-s", SERVICE, "-a", account, "-w"]);
      return stdout.replace(/\n$/, "") || undefined;
    } catch {
      return undefined; // exit 44: not found
    }
  }

  /** The secret goes through stdin (`security -i`), never the command line. */
  async set(account: string, value: string) {
    const quote = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
    await new Promise<void>((resolve, reject) => {
      const child = spawn("security", ["-i"], { stdio: ["pipe", "ignore", "pipe"] });
      let err = "";
      child.stderr.on("data", (d) => (err += d));
      child.on("error", reject);
      child.on("exit", (code) => (code === 0 && !err.trim() ? resolve() : reject(new Error(err.trim() || `security exited ${code}`))));
      child.stdin.end(`add-generic-password -U -s ${quote(SERVICE)} -a ${quote(account)} -l ${quote(`${SERVICE} · ${account}`)} -w ${quote(value)}\n`);
    });
  }

  async delete(account: string) {
    await run("security", ["delete-generic-password", "-s", SERVICE, "-a", account]).catch(() => {});
  }
}

class FileStore implements Backend {
  readonly label = "local file";
  private path = join(HOME, "secrets.json");

  private read(): Record<string, string> {
    return existsSync(this.path) ? JSON.parse(readFileSync(this.path, "utf8")) : {};
  }

  private write(all: Record<string, string>) {
    mkdirSync(HOME, { recursive: true });
    writeFileSync(this.path, JSON.stringify(all, null, 2), { mode: 0o600 });
  }

  async get(account: string) {
    return this.read()[account];
  }

  async set(account: string, value: string) {
    this.write({ ...this.read(), [account]: value });
  }

  async delete(account: string) {
    const all = this.read();
    delete all[account];
    this.write(all);
  }
}

class Secrets {
  // LOCALBOT_SECRETS=file forces the file store (tests, and hosts without a keychain).
  private backend: Backend =
    platform() === "darwin" && process.env.LOCALBOT_SECRETS !== "file" ? new MacKeychain() : new FileStore();
  private cache = new Map<string, string>();

  get storeLabel() {
    return this.backend.label;
  }

  /** Loads the given accounts into memory so lookups can be synchronous. */
  async load(accounts: string[]) {
    await Promise.all(accounts.map(async (a) => {
      const v = await this.backend.get(a);
      if (v) this.cache.set(a, v);
    }));
  }

  get(account: string) {
    return this.cache.get(account);
  }

  async set(account: string, value: string) {
    await this.backend.set(account, value);
    this.cache.set(account, value);
  }

  async delete(account: string) {
    await this.backend.delete(account);
    this.cache.delete(account);
  }
}

export const secrets = new Secrets();
