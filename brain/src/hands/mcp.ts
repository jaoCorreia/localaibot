import type { Hands, Screenshot } from "./types.ts";

/**
 * Minimal MCP client over Streamable HTTP: JSON-RPC requests POSTed to one
 * URL, answered as JSON or as a short SSE stream. Enough to drive a device's
 * hands; no server-initiated messages.
 */
export class McpClient {
  private sessionId?: string;
  private initialized?: Promise<void>;
  private nextId = 1;

  constructor(private url: string, private token?: string, private timeoutMs = 90_000, private who = "The device") {}

  /** Calls a tool and returns its result (content, structuredContent, isError). */
  async callTool(name: string, args: Record<string, unknown>, timeoutMs?: number): Promise<ToolResult> {
    await this.initialize();
    return this.request("tools/call", { name, arguments: args }, timeoutMs);
  }

  async listTools(): Promise<{ name: string; description?: string; inputSchema?: Record<string, unknown> }[]> {
    await this.initialize();
    return (await this.request("tools/list", {})).tools ?? [];
  }

  private initialize() {
    this.initialized ??= (async () => {
      await this.request("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "localbot-brain", version: "0.1.0" },
      });
      await this.post({ jsonrpc: "2.0", method: "notifications/initialized" });
    })().catch((err) => {
      this.initialized = undefined; // retry on the next call
      throw err;
    });
    return this.initialized;
  }

  private async request(method: string, params: unknown, timeoutMs?: number): Promise<any> {
    const id = this.nextId++;
    const reply = await this.post({ jsonrpc: "2.0", id, method, params }, timeoutMs);
    if (reply?.error) throw new Error(reply.error.message ?? `MCP error ${reply.error.code}`);
    return reply?.result;
  }

  private async post(message: object, timeoutMs = this.timeoutMs): Promise<any> {
    const res = await fetch(this.url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        ...(this.token ? { authorization: `Bearer ${this.token}` } : {}),
        ...(this.sessionId ? { "mcp-session-id": this.sessionId } : {}),
      },
      body: JSON.stringify(message),
      signal: AbortSignal.timeout(timeoutMs),
    });
    this.sessionId = res.headers.get("mcp-session-id") ?? this.sessionId;
    if (res.status === 401 || res.status === 403) throw new Error(`${this.who} refused the token`);
    if (res.status === 202) return undefined;
    if (!res.ok) throw new Error(`${this.who} answered HTTP ${res.status}`);
    const body = await res.text();
    if (!(res.headers.get("content-type") ?? "").includes("text/event-stream")) return body ? JSON.parse(body) : undefined;
    // SSE: the reply is the last `data:` event that carries an id.
    const events = body.split(/\n\n/).map((e) =>
      e.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("\n"),
    ).filter(Boolean).map((d) => JSON.parse(d));
    return events.reverse().find((e) => "id" in e) ?? events[0];
  }
}

export interface ToolResult {
  content?: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[];
  structuredContent?: any;
  isError?: boolean;
}

const textOf = (r: ToolResult) =>
  (r.content ?? []).filter((c): c is { type: "text"; text: string } => c.type === "text").map((c) => c.text).join("\n");

/**
 * Hands on any device that speaks the Local Bot device tools over MCP:
 * `describe`, `screenshot`, `computer` (a Cua Driver call) and `shell`.
 * The device image in /device serves them; other providers can too.
 */
export class McpHands implements Hands {
  constructor(private client: McpClient, private session: string, private description: string) {}

  /** Connects and reads the device's own description. */
  static async connect(client: McpClient, session: string) {
    const fallback = "Device: a remote computer with a desktop.";
    const description = await client.callTool("describe", {}).then((r) => textOf(r) || fallback, () => fallback);
    return new McpHands(client, session, description);
  }

  describe() {
    return this.description;
  }

  async screenshot(): Promise<Screenshot> {
    const r = await this.client.callTool("screenshot", { session: this.session });
    if (r.isError) throw new Error(textOf(r) || "Screenshot failed");
    const image = r.content?.find((c) => c.type === "image") as { data: string } | undefined;
    if (!image) throw new Error("The device sent no screenshot");
    return { png: image.data, width: r.structuredContent?.width ?? 1280, height: r.structuredContent?.height ?? 900 };
  }

  async act(tool: string, args: Record<string, unknown>) {
    const desktop = tool === "launch_app" ? {} : { scope: "desktop", delivery_mode: "foreground" };
    const r = await this.client.callTool("computer", { tool, session: this.session, args: { ...desktop, ...args } });
    if (r.isError) throw new Error(textOf(r) || `${tool} failed`);
    if (r.structuredContent !== undefined) return r.structuredContent;
    const text = textOf(r);
    try {
      return JSON.parse(text);
    } catch {
      return { message: text };
    }
  }

  async shell(command: string, timeoutMs = 60_000) {
    try {
      const r = await this.client.callTool("shell", { command, timeout_ms: timeoutMs }, timeoutMs + 15_000);
      return r.structuredContent ?? { code: r.isError ? 1 : 0, output: textOf(r) };
    } catch (err) {
      return { code: 1, output: err instanceof Error ? err.message : String(err) };
    }
  }
}
