import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import type { ToolResult } from "../hands/mcp.ts";

/**
 * MCP client for a local server: starts its command and speaks JSON-RPC as
 * newline-delimited JSON on its stdio. Started on first use; if the process
 * dies, the next call starts it again.
 */
export class StdioMcpClient {
  private child?: ChildProcess;
  private ready?: Promise<void>;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  /** The last lines the server wrote to stderr, for "recent errors". */
  stderr: string[] = [];

  constructor(
    private command: string,
    private args: string[],
    private env: Record<string, string>,
    private timeoutMs = 120_000,
  ) {}

  async listTools(): Promise<{ name: string; description?: string; inputSchema?: Record<string, unknown> }[]> {
    await this.start();
    return (await this.request("tools/list", {})).tools ?? [];
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<ToolResult> {
    await this.start();
    return this.request("tools/call", { name, arguments: args });
  }

  stop() {
    this.child?.kill();
    this.child = undefined;
    this.ready = undefined;
  }

  private start() {
    this.ready ??= (async () => {
      const child = spawn(this.command, this.args, {
        env: { ...process.env, ...this.env },
        stdio: ["pipe", "pipe", "pipe"],
      });
      this.child = child;
      const failAll = (err: Error) => {
        for (const p of this.pending.values()) p.reject(err);
        this.pending.clear();
        if (this.child === child) { this.child = undefined; this.ready = undefined; }
      };
      child.on("error", (err) => failAll(new Error(`Couldn’t start “${this.command}”: ${err.message}`)));
      child.on("exit", (code) => failAll(new Error(`The server stopped (exit ${code ?? "signal"})${this.lastError()}`)));
      createInterface({ input: child.stderr! }).on("line", (line) => {
        this.stderr.push(line);
        if (this.stderr.length > 20) this.stderr.shift();
      });
      createInterface({ input: child.stdout! }).on("line", (line) => {
        let msg: any;
        try { msg = JSON.parse(line); } catch { return; }
        if (msg.id === undefined || !this.pending.has(msg.id)) return;
        const p = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message ?? `MCP error ${msg.error.code}`));
        else p.resolve(msg.result);
      });
      await this.request("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "localbot-brain", version: "0.1.0" },
      });
      this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
    })().catch((err) => {
      this.stop();
      throw err;
    });
    return this.ready;
  }

  private lastError() {
    const last = this.stderr.at(-1);
    return last ? `: ${last}` : "";
  }

  private send(message: object) {
    this.child?.stdin?.write(JSON.stringify(message) + "\n");
  }

  private request(method: string, params: unknown): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`The server didn’t answer ${method} in time`));
      }, this.timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }
}
