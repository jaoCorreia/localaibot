import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { CloudLink } from "../src/cloud/link.ts";

test("cloud RPC remains usable while authenticated events stream on a dedicated socket", async () => {
  const token = "cloud-test-token-123456";
  let stream: ServerResponse | undefined;
  let connected!: () => void;
  const listening = new Promise<void>((resolve) => { connected = resolve; });
  const server = createServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${token}`) return res.writeHead(401).end();
    if (req.url === "/events") {
      stream = res;
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(": connected\n\n");
      connected();
      return;
    }
    let body = "";
    for await (const chunk of req) body += chunk;
    assert.equal(JSON.parse(body).method, "ping");
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ result: "pong" }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const fetch = globalThis.fetch;
  // Streaming on fetch would share the RPC pool and reproduce the production failure.
  globalThis.fetch = (input, options) => {
    assert.ok(!String(input).endsWith("/events"));
    return fetch(input, options);
  };
  let received!: () => void;
  const event = new Promise<void>((resolve) => { received = resolve; });
  const link = new CloudLink((name, data) => {
    if (name === "memory" && typeof data === "object" && data !== null && "text" in data && data.text === "ação") received();
  }, () => {});
  try {
    await link.connect(url, token);
    await listening;
    assert.equal(await link.call("ping"), "pong");
    stream!.write('data: {"event":"memory","data":{"text":"ação"}}\n\n');
    await event;
  } finally {
    await link.disconnect();
    globalThis.fetch = fetch;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
