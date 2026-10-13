import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { homedir, platform } from "node:os";
import { join } from "node:path";
import type { Computer, ComputerProvider } from "./types.ts";

/** macOS VMs created by Lume, stored as ~/.lume/<name>/{config.json,disk.img,nvram.bin}. */
export class LumeProvider implements ComputerProvider {
  readonly name = "lume";
  /** Creations started from this app that Lume hasn't put on disk yet. */
  private pending = new Map<string, { error?: string }>();
  constructor(private root = join(homedir(), ".lume")) {}

  async available() {
    return platform() === "darwin" && process.arch === "arm64";
  }

  async list(): Promise<Computer[]> {
    const onDisk = existsSync(this.root)
      ? readdirSync(this.root, { withFileTypes: true })
          .filter((d) => d.isDirectory() && existsSync(join(this.root, d.name, "config.json")))
          .map((d) => this.read(d.name))
      : [];
    const early: Computer[] = [...this.pending]
      .filter(([name]) => !onDisk.some((c) => c.name === name))
      .map(([name, p]) => ({
        id: `lume:${name}`, name, provider: this.name, os: "macos",
        state: p.error ? "error" : "creating", display: { kind: "none" },
      }));
    return [...onDisk, ...early];
  }

  /**
   * Downloads macOS and installs it unattended (long: ~17 GB download).
   * Runs detached; the device shows as "creating" until Lume clears its
   * provisioning marker. Apple allows two macOS VMs running per Mac.
   */
  async create(label: string): Promise<string> {
    const name = label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "mac";
    if (existsSync(join(this.root, name))) throw new Error(`A macOS device named ${name} already exists`);
    mkdirSync(this.root, { recursive: true });
    const lume = join(homedir(), ".local", "bin", "lume");
    const child = spawn(lume, [
      "create", name, "--ipsw", "latest", "--unattended", "tahoe",
      "--cpu", "4", "--memory", "8GB", "--disk-size", "60GB", "--display", "1440x900",
    ], { detached: true, stdio: "ignore" });
    this.pending.set(name, {});
    child.on("exit", (code) => {
      if (code === 0) this.pending.delete(name);
      else this.pending.set(name, { error: `lume create exited with ${code}` });
    });
    child.on("error", (err) => this.pending.set(name, { error: err.message }));
    child.unref();
    return `lume:${name}`;
  }

  async remove(id: string) {
    const name = id.replace(/^lume:/, "");
    if (this.pending.get(name)?.error) return void this.pending.delete(name);
    const lume = join(homedir(), ".local", "bin", "lume");
    await new Promise<void>((resolve, reject) => {
      spawn(lume, ["delete", name, "--force"], { stdio: "ignore" })
        .on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`lume delete exited with ${code}`))))
        .on("error", reject);
    });
  }

  private read(name: string): Computer {
    const dir = join(this.root, name);
    const config = JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
    const ready =
      existsSync(join(dir, "disk.img")) &&
      existsSync(join(dir, "nvram.bin")) &&
      !existsSync(join(dir, ".provisioning"));
    return {
      id: `lume:${name}`,
      name,
      provider: this.name,
      os: String(config.os).toLowerCase() === "macos" ? "macos" : "linux",
      // Running state is owned by the shell that boots it; the provider only knows readiness.
      state: ready ? "stopped" : "creating",
      cpu: config.cpuCount,
      memoryGB: config.memorySize ? Math.round(config.memorySize / 2 ** 30) : undefined,
      display: { kind: "native-vz", bundlePath: dir },
    };
  }
}
