import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { McpServers } from "../src/mcp/servers.ts";

/**
 * A fake service with an MCP server behind the MCP authorization spec:
 * protected-resource metadata, an authorization server with dynamic client
 * registration and PKCE, short-lived access tokens and refresh tokens.
 */
async function fakeService() {
  const state = { registered: 0, refreshed: 0, issued: 0, codes: new Map<string, { verifier?: string; challenge: string; redirect: string }>() };
  const valid = new Set<string>();
  const server = createServer(async (req, res) => {
    const url = new URL(req.url!, base);
    const body = await new Promise<string>((r) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => r(b)); });
    const json = (code: number, data: unknown, headers: Record<string, string> = {}) =>
      res.writeHead(code, { "content-type": "application/json", ...headers }).end(JSON.stringify(data));

    if (url.pathname === "/mcp") {
      const token = /^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      if (!token || !valid.has(token)) {
        return json(401, { error: "unauthorized" }, { "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"` });
      }
      const msg = JSON.parse(body);
      if (msg.id === undefined) return res.writeHead(202).end();
      const reply = (result: unknown) => json(200, { jsonrpc: "2.0", id: msg.id, result });
      if (msg.method === "initialize") return reply({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1" } });
      if (msg.method === "tools/list") return reply({ tools: [{ name: "whoami", description: "Who is signed in", inputSchema: { type: "object", properties: {} } }] });
      if (msg.method === "tools/call") return reply({ content: [{ type: "text", text: "signed in as patrick" }] });
    }
    if (url.pathname === "/.well-known/oauth-protected-resource/mcp") return json(200, { resource: `${base}/mcp`, authorization_servers: [base] });
    if (url.pathname === "/.well-known/oauth-authorization-server") {
      return json(200, { issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`, registration_endpoint: `${base}/register` });
    }
    if (url.pathname === "/register") {
      state.registered++;
      return json(201, { client_id: `client-${state.registered}`, redirect_uris: JSON.parse(body).redirect_uris });
    }
    if (url.pathname === "/authorize") {
      // The "user" signs in at once: back to Local Bot with a code.
      assert.equal(url.searchParams.get("code_challenge_method"), "S256");
      assert.equal(url.searchParams.get("resource"), `${base}/mcp`);
      const code = `code-${Math.random()}`;
      state.codes.set(code, { challenge: url.searchParams.get("code_challenge")!, redirect: url.searchParams.get("redirect_uri")! });
      const back = new URL(url.searchParams.get("redirect_uri")!);
      back.searchParams.set("code", code);
      back.searchParams.set("state", url.searchParams.get("state")!);
      return res.writeHead(302, { location: back.toString() }).end();
    }
    if (url.pathname === "/token") {
      const form = new URLSearchParams(body);
      const issue = () => {
        const access = `access-${++state.issued}`;
        valid.clear();
        valid.add(access);
        return { access_token: access, refresh_token: `refresh-${state.issued}`, expires_in: 3600, token_type: "Bearer" };
      };
      if (form.get("grant_type") === "authorization_code") {
        const pending = state.codes.get(form.get("code")!);
        const { createHash } = await import("node:crypto");
        const ok = pending && createHash("sha256").update(form.get("code_verifier")!).digest("base64url") === pending.challenge;
        return ok ? json(200, issue()) : json(400, { error: "invalid_grant" });
      }
      if (form.get("grant_type") === "refresh_token") { state.refreshed++; return json(200, issue()); }
    }
    res.writeHead(404).end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { base, state, valid, close: () => server.close() };
}

test("a connector signs in with OAuth, uses its tools and refreshes an expired token", async () => {
  const svc = await fakeService();
  const mcp = new McpServers();
  const server = mcp.connector({ id: "fake", name: "Fake", url: `${svc.base}/mcp` });
  assert.equal(mcp.list().find((s) => s.id === server.id)?.state, "signin");
  // Not offered to bots until signed in.
  assert.deepEqual(await mcp.toolsFor([]), []);

  const pageURL = await mcp.signIn(server.id);
  // The browser: follow the sign-in page back to Local Bot's loopback address.
  const callback = await fetch(pageURL, { redirect: "follow" });
  assert.match(await callback.text(), /Connected to Local Bot/);
  for (let i = 0; i < 50 && mcp.list()[0].state !== "connected"; i++) await new Promise((r) => setTimeout(r, 20));

  const view = mcp.list().find((s) => s.id === server.id)!;
  assert.equal(view.state, "connected");
  assert.deepEqual(view.tools?.map((t) => t.name), ["whoami"]);
  assert.equal(svc.state.registered, 1);

  // Every bot gets it (connectors are for all bots by default).
  assert.deepEqual((await mcp.toolsFor([])).map((t) => t.name), ["fake__whoami"]);
  assert.equal((await mcp.call([], "fake__whoami", "{}"))?.result, "signed in as patrick");

  // The service drops the token: the next call refreshes and retries.
  svc.valid.clear();
  assert.equal((await mcp.call([], "fake__whoami", "{}"))?.result, "signed in as patrick");
  assert.equal(svc.state.refreshed, 1);

  await mcp.remove(server.id);
  svc.close();
});
