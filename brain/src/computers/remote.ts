import { randomBytes } from "node:crypto";
import { McpClient, McpHands } from "../hands/mcp.ts";
import { secrets } from "../secrets.ts";
import { Collection } from "../store.ts";
import type { Computer, ComputerProvider } from "./types.ts";

/**
 * A device reached over the network: anything that serves the Local Bot
 * device agent (the image in /device) or, more generally, an MCP endpoint
 * with the `screenshot`, `computer` and `shell` tools. Cloud providers
 * (Railway today) create the machine, then hand it to the same plumbing.
 */
export interface RemoteEndpoint {
  /** Base URL of the agent, e.g. https://device.up.railway.app */
  url: string;
  /** Path of the MCP endpoint under `url`. */
  mcpPath?: string;
}

const tokenAccount = (id: string) => `device:${id}`;

export const remote = {
  tokenAccount,
  token: (id: string) => secrets.get(tokenAccount(id)),

  newToken: () => randomBytes(24).toString("base64url"),

  client(endpoint: RemoteEndpoint, token?: string) {
    return new McpClient(`${endpoint.url}${endpoint.mcpPath ?? "/mcp"}`, token);
  },

  /** True when the agent answers its health check. */
  async healthy(url: string) {
    try {
      const res = await fetch(`${url}/health`, { signal: AbortSignal.timeout(4000) });
      return res.ok;
    } catch {
      return false;
    }
  },

  /** noVNC through the agent; the token opens a cookie session for the page. */
  display(url: string, token: string | undefined, password?: string): Computer["display"] {
    return { kind: "vnc", url: `${url}/vnc_lite.html?token=${encodeURIComponent(token ?? "")}`, password };
  },

  hands(endpoint: RemoteEndpoint, id: string, session: string) {
    return McpHands.connect(remote.client(endpoint, remote.token(id)), session);
  },
};

export function normalizeURL(raw: string) {
  const url = raw.trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^/]+/i.test(url)) throw new Error("Use a full URL, like https://my-device.example.com");
  if (/^http:\/\//i.test(url) && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/i.test(url)) {
    throw new Error("Use https:// so the token isn’t sent in the clear");
  }
  return url;
}

interface RemoteRecord {
  id: string;
  name: string;
  url: string;
  mcpPath?: string;
  vncPassword?: string;
}

/** Machines the user connects by URL + token (a VPS, another host, a future provider). */
export class RemoteProvider implements ComputerProvider {
  readonly name = "remote";
  private devices = new Collection<RemoteRecord>("remote-devices.json", 0o600);

  async load() {
    await secrets.load(this.devices.all().map((d) => tokenAccount(d.id)));
  }

  async available() {
    return true;
  }

  async list(): Promise<Computer[]> {
    return Promise.all(this.devices.all().map(async (d) => ({
      id: d.id,
      name: d.name,
      provider: this.name,
      os: "linux" as const,
      state: (await remote.healthy(d.url)) ? "running" as const : "stopped" as const,
      display: remote.display(d.url, remote.token(d.id), d.vncPassword),
    })));
  }

  /** Checks the endpoint answers with the device tools before saving it. */
  async create(name: string, options: Record<string, string> = {}) {
    const url = normalizeURL(options.url ?? "");
    const token = options.token?.trim();
    if (!token) throw new Error("Paste the device’s token");
    const tools = await remote.client({ url }, token).listTools()
      .catch((err) => { throw new Error(`Couldn’t reach the device: ${err.message}`); });
    const missing = ["screenshot", "computer", "shell"].filter((t) => !tools.some((x) => x.name === t));
    if (missing.length) throw new Error(`That endpoint is missing the ${missing.join(", ")} tool${missing.length > 1 ? "s" : ""}`);
    const id = `remote:${randomBytes(4).toString("hex")}`;
    await secrets.set(tokenAccount(id), token);
    this.devices.upsert({ id, name, url, vncPassword: options.vncPassword?.trim() || undefined });
    return id;
  }

  /** Forgets the device; the machine itself is left alone. */
  async remove(id: string) {
    this.devices.remove((d) => d.id === id);
    await secrets.delete(tokenAccount(id));
  }

  async hands(id: string, session: string) {
    const d = this.devices.get(id);
    if (!d || !(await remote.healthy(d.url))) return null;
    return remote.hands(d, id, session);
  }
}
