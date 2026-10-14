import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";

const { normalizeURL, RemoteProvider } = await import("../src/computers/remote.ts");
const { decodeShare, encodeShare } = await import("../src/computers/share.ts");

const TOKEN = "secret-token-1234567890";

/** A fake device agent: MCP over HTTP with the device tools, answering in SSE. */
const server = createServer(async (req, res) => {
  if (req.url === "/health") return res.writeHead(200).end("{}");
  if (req.headers.authorization !== `Bearer ${TOKEN}`) return res.writeHead(401).end();
  let raw = "";
  for await (const c of req) raw += c;
  const msg = JSON.parse(raw);
  if (msg.id === undefined) return res.writeHead(202).end();
  const result =
    msg.method === "initialize" ? { protocolVersion: "2025-06-18", capabilities: { tools: {} } }
    : msg.method === "tools/list" ? { tools: [{ name: "describe" }, { name: "screenshot" }, { name: "computer" }, { name: "shell" }] }
    : msg.params.name === "describe" ? { content: [{ type: "text", text: "Device: fake" }] }
    : msg.params.name === "screenshot" ? { content: [{ type: "image", data: "UE5H", mimeType: "image/png" }], structuredContent: { width: 800, height: 600 } }
    : msg.params.name === "computer" ? { content: [{ type: "text", text: JSON.stringify({ echoed: msg.params.arguments }) }] }
    : { structuredContent: { code: 0, output: `ran ${msg.params.arguments.command}` } };
  res.writeHead(200, { "content-type": "text/event-stream", "mcp-session-id": "s1" });
  res.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result })}\n\n`);
});
await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => server.close());

test("URLs must be complete, and https unless local", () => {
  assert.equal(normalizeURL(" https://a.example.com/ "), "https://a.example.com");
  assert.equal(normalizeURL("http://localhost:8080"), "http://localhost:8080");
  assert.throws(() => normalizeURL("a.example.com"));
  assert.throws(() => normalizeURL("http://a.example.com"));
});

test("a connected machine is checked, then driven over MCP", async () => {
  const p = new RemoteProvider();
  await assert.rejects(p.create("Bad", { url, token: "wrong" }), /refused the token/);

  const id = await p.create("Box", { url, token: TOKEN });
  const [device] = await p.list();
  assert.equal(device.state, "running");
  assert.match((device.display as { url: string }).url, /vnc_lite\.html\?token=secret-token/);

  const hands = (await p.hands(id, "s"))!;
  assert.equal(hands.describe(), "Device: fake");
  assert.deepEqual(await hands.screenshot(), { png: "UE5H", width: 800, height: 600 });
  const acted: any = await hands.act("click", { x: 1, y: 2 });
  assert.deepEqual(acted.echoed, { tool: "click", session: "s", args: { scope: "desktop", delivery_mode: "foreground", x: 1, y: 2 } });
  assert.deepEqual(await hands.shell("ls"), { code: 0, output: "ran ls" });

  await p.remove(id);
  assert.equal((await p.list()).length, 0);
});

test("share codes round-trip, also inside a link", () => {
  const d = { url: "https://d.example.com", token: "t0k3n", vncPassword: "pw", name: "Box" };
  const code = encodeShare(d);
  assert.match(code, /^localbot-device:[\w-]+$/);
  assert.deepEqual(decodeShare(` ${code} `), d);
  assert.deepEqual(decodeShare(`https://localbot.app/connect?d=${code.slice("localbot-device:".length)}`), d);
  assert.throws(() => decodeShare("nonsense!"), /isn’t a device share code/);
});

test("a shared device connects from its code alone", async () => {
  const p = new RemoteProvider();
  const id = await p.create("Shared", { code: encodeShare({ url, token: TOKEN, vncPassword: "pw" }) });
  assert.deepEqual(decodeShare(await p.share(id)), { url, token: TOKEN, vncPassword: "pw", name: "Shared" });
  await p.remove(id);
});
