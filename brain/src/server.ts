import { timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { events, invoke, log } from "./core.ts";

/**
 * Brain entry point for the cloud: the same methods as the local app's stdio
 * protocol, over HTTP, guarded by BRAIN_TOKEN. Bots hosted here keep working
 * (chats, routines, memory) while the Mac is off; the local brain forwards to
 * it and relays its events (see cloud/link.ts).
 *   POST /rpc     {method, params}  ->  {result} | {error}
 *   GET  /events  server-sent events, one `{event, data}` per message
 *   GET  /health  unauthenticated liveness probe
 */
const PORT = Number(process.env.PORT ?? 8080);
const TOKEN = process.env.BRAIN_TOKEN ?? "";

if (TOKEN.length < 16) {
  log("BRAIN_TOKEN must be set (16+ characters); refusing to start.");
  process.exit(1);
}

function authorized(req: IncomingMessage) {
  const given = Buffer.from(/^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1] ?? "");
  const want = Buffer.from(TOKEN);
  return given.length === want.length && timingSafeEqual(given, want);
}

function send(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage) {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

const streams = new Set<ServerResponse>();
events.on("event", (event: string, data: unknown) => {
  const line = `data: ${JSON.stringify({ event, data })}\n\n`;
  for (const res of streams) res.write(line);
});
// Keeps idle connections open through proxies.
setInterval(() => { for (const res of streams) res.write(": ping\n\n"); }, 20_000).unref();

const server = createServer(async (req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  if (path === "/health") return send(res, 200, { ok: true });
  if (!authorized(req)) return send(res, 401, { error: "unauthorized" });

  if (path === "/events" && req.method === "GET") {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
    res.write(": connected\n\n");
    streams.add(res);
    req.on("close", () => streams.delete(res));
    return;
  }

  if (path === "/rpc" && req.method === "POST") {
    let msg: { method?: string; params?: unknown };
    try {
      msg = JSON.parse(await readBody(req));
    } catch {
      return send(res, 400, { error: "invalid JSON" });
    }
    try {
      return send(res, 200, { result: await invoke(String(msg.method), msg.params) });
    } catch (err) {
      return send(res, 200, { error: err instanceof Error ? err.message : String(err) });
    }
  }

  send(res, 404, { error: "not found" });
});

server.listen(PORT, "0.0.0.0", () => log(`cloud brain on :${PORT}`));
