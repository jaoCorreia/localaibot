// Local Bot device agent. One HTTP port, guarded by LOCALBOT_TOKEN:
//   POST /mcp   MCP (Streamable HTTP, JSON responses): the device's hands —
//               screenshot, Cua Driver calls, shell.
//   GET  /health  unauthenticated liveness probe.
//   anything else  the noVNC screen (127.0.0.1:6901), websocket included.
//               Open it once with ?token=… and a cookie keeps the session.
// Any host that can run this image (or speak these MCP tools) can be a device.
import { execFile } from "node:child_process";
import { timingSafeEqual } from "node:crypto";
import { readFile, unlink } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { promisify } from "node:util";

const run = promisify(execFile);
const PORT = Number(process.env.PORT ?? 8080);
const TOKEN = process.env.LOCALBOT_TOKEN ?? "";
const NOVNC = { host: "127.0.0.1", port: Number(process.env.NOVNC_PORT ?? 6901) };
const DRIVER = "/home/cua/.local/bin/cua-driver";
const COOKIE = "localbot_token";

if (TOKEN.length < 16) {
  console.error("LOCALBOT_TOKEN must be set (16+ characters); refusing to start.");
  process.exit(1);
}

const same = (a, b) => {
  const x = Buffer.from(String(a ?? "")), y = Buffer.from(TOKEN);
  return x.length === y.length && timingSafeEqual(x, y);
};

function cookieToken(req) {
  const m = new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`).exec(req.headers.cookie ?? "");
  return m ? decodeURIComponent(m[1]) : undefined;
}

function bearer(req) {
  return /^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1];
}

// ---------------------------------------------------------------- hands

async function driver(tool, args) {
  const { stdout } = await run(DRIVER, ["call", tool, JSON.stringify(args)], {
    env: { ...process.env, DISPLAY: ":1" },
    timeout: 60_000,
    maxBuffer: 32 * 1024 * 1024,
  });
  const out = String(stdout).trim();
  try {
    return JSON.parse(out);
  } catch {
    return { message: out };
  }
}

/** Cua Driver ends idle sessions; reopen and retry once. */
async function call(tool, args) {
  try {
    return await driver(tool, args);
  } catch (err) {
    const msg = `${err.message ?? ""}${err.stdout ?? ""}${err.stderr ?? ""}`;
    if (!/session has ended|session_ended/i.test(msg)) throw err;
    await driver("start_session", { session: args.session });
    return driver(tool, args);
  }
}

async function shell(command, timeoutMs = 60_000) {
  try {
    const { stdout, stderr } = await run("bash", ["-lc", command], { timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 });
    return { code: 0, output: `${stdout}${stderr}` };
  } catch (err) {
    const output = `${err.stdout ?? ""}${err.stderr ?? ""}` || err.message;
    return { code: typeof err.code === "number" ? err.code : 1, output: err.killed ? `${output}\n(timed out)` : output };
  }
}

const text = (value) => ({ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) });

const tools = [
  {
    name: "describe",
    description: "Short description of this machine for the model.",
    inputSchema: { type: "object", properties: {} },
    run: async () => ({
      content: [text([
        "Device: Debian Linux with an XFCE desktop, 1280x900 screen, user `cua`.",
        "Apps: Firefox ESR (`firefox-esr`), terminal, file manager. No sudo password.",
      ].join("\n"))],
    }),
  },
  {
    name: "screenshot",
    description: "PNG of the whole screen.",
    inputSchema: { type: "object", properties: { session: { type: "string" } } },
    run: async ({ session = "default" }) => {
      const file = `/tmp/localbot-${String(session).replace(/[^\w-]/g, "")}.png`;
      const meta = await call("get_desktop_state", { session, screenshot_out_file: file });
      const png = await readFile(file);
      await unlink(file).catch(() => {});
      const size = { width: meta.screenshot_width ?? 1280, height: meta.screenshot_height ?? 900 };
      return {
        content: [{ type: "image", data: png.toString("base64"), mimeType: "image/png" }, text(size)],
        structuredContent: size,
      };
    },
  },
  {
    name: "computer",
    description: "A Cua Driver tool call (click, type_text, press_key, hotkey, scroll, launch_app…).",
    inputSchema: {
      type: "object",
      properties: { tool: { type: "string" }, args: { type: "object" }, session: { type: "string" } },
      required: ["tool"],
    },
    run: async ({ tool, args = {}, session = "default" }) => {
      const result = await call(String(tool), { session, ...args });
      const refusal = result?.refusal?.message ?? (result?.status === "refused" ? result?.message : undefined);
      return refusal ? { content: [text(refusal)], isError: true } : { content: [text(result)], structuredContent: result };
    },
  },
  {
    name: "shell",
    description: "Runs a bash command as the desktop user.",
    inputSchema: {
      type: "object",
      properties: { command: { type: "string" }, timeout_ms: { type: "number" } },
      required: ["command"],
    },
    run: async ({ command, timeout_ms }) => {
      const result = await shell(String(command), Number(timeout_ms) || 60_000);
      return { content: [text(result.output)], structuredContent: result };
    },
  },
];

// ---------------------------------------------------------------- MCP

async function rpc(msg) {
  const { id, method, params = {} } = msg;
  if (id === undefined) return undefined; // notification
  try {
    switch (method) {
      case "initialize":
        return {
          jsonrpc: "2.0", id,
          result: {
            protocolVersion: params.protocolVersion ?? "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "localbot-device", version: "0.1.0" },
          },
        };
      case "ping":
        return { jsonrpc: "2.0", id, result: {} };
      case "tools/list":
        return { jsonrpc: "2.0", id, result: { tools: tools.map(({ run, ...t }) => t) } };
      case "tools/call": {
        const tool = tools.find((t) => t.name === params.name);
        if (!tool) return { jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${params.name}` } };
        try {
          return { jsonrpc: "2.0", id, result: await tool.run(params.arguments ?? {}) };
        } catch (err) {
          return { jsonrpc: "2.0", id, result: { content: [text(err.message ?? String(err))], isError: true } };
        }
      }
      default:
        return { jsonrpc: "2.0", id, error: { code: -32601, message: `Unknown method: ${method}` } };
    }
  } catch (err) {
    return { jsonrpc: "2.0", id, error: { code: -32603, message: err.message ?? String(err) } };
  }
}

async function body(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

async function mcp(req, res) {
  if (!same(bearer(req))) return send(res, 401, { error: "unauthorized" });
  if (req.method !== "POST") return send(res, 405, { error: "POST only" });
  let msg;
  try {
    msg = JSON.parse(await body(req));
  } catch {
    return send(res, 400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  const replies = (await Promise.all((Array.isArray(msg) ? msg : [msg]).map(rpc))).filter(Boolean);
  if (!replies.length) return res.writeHead(202).end();
  send(res, 200, Array.isArray(msg) ? replies : replies[0]);
}

function send(res, status, value) {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(value));
}

// ---------------------------------------------------------------- screen

/** Strips `token` from the URL; true when the request carries a valid token. */
function screenAuth(req, res) {
  const url = new URL(req.url, "http://x");
  const q = url.searchParams.get("token");
  if (q !== null) {
    url.searchParams.delete("token");
    req.url = url.pathname + url.search;
    if (same(q)) {
      const secure = req.headers["x-forwarded-proto"] === "https" ? "; Secure" : "";
      res?.setHeader("set-cookie", `${COOKIE}=${encodeURIComponent(q)}; Path=/; HttpOnly; SameSite=Lax${secure}`);
      return true;
    }
  }
  return same(cookieToken(req));
}

function proxy(req, res) {
  if (!screenAuth(req, res)) return send(res, 401, { error: "unauthorized" });
  const headers = { ...req.headers, host: `${NOVNC.host}:${NOVNC.port}` };
  delete headers.cookie;
  const up = http.request({ ...NOVNC, method: req.method, path: req.url, headers }, (r) => {
    res.writeHead(r.statusCode ?? 502, r.headers);
    r.pipe(res);
  });
  // noVNC starts a few seconds after the agent: tell browsers to come back.
  up.on("error", () => {
    res.writeHead(503, { "content-type": "text/html", "retry-after": "2" })
      .end('<!doctype html><meta http-equiv="refresh" content="2"><title>Starting…</title>');
  });
  req.pipe(up);
}

const server = http.createServer((req, res) => {
  const path = req.url.split("?")[0];
  if (path === "/health") return send(res, 200, { ok: true });
  if (path === "/mcp") return mcp(req, res).catch((err) => send(res, 500, { error: err.message }));
  proxy(req, res);
});

// noVNC's websocket: authenticate by cookie, then splice the raw streams.
server.on("upgrade", (req, socket, head) => {
  if (!screenAuth(req)) {
    socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return;
  }
  const up = net.connect(NOVNC.port, NOVNC.host, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const k = req.rawHeaders[i];
      if (/^(cookie|host)$/i.test(k)) continue;
      lines.push(`${k}: ${req.rawHeaders[i + 1]}`);
    }
    lines.push(`Host: ${NOVNC.host}:${NOVNC.port}`);
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head?.length) up.write(head);
    up.pipe(socket).pipe(up);
  });
  const close = () => { up.destroy(); socket.destroy(); };
  up.on("error", close);
  socket.on("error", close);
});

/**
 * The share code to paste into Local Bot's "Connect a machine", printed when
 * the public URL is known: LOCALBOT_PUBLIC_URL, or Railway's own domain.
 * Same format as brain/src/computers/share.ts.
 */
function shareCode() {
  const domain = process.env.RAILWAY_PUBLIC_DOMAIN;
  const url = (process.env.LOCALBOT_PUBLIC_URL ?? (domain ? `https://${domain}` : "")).replace(/\/+$/, "");
  if (!url) return undefined;
  const payload = { v: 1, url, token: TOKEN, ...(process.env.VNC_PW ? { vnc: process.env.VNC_PW } : {}) };
  return "localbot-device:" + Buffer.from(JSON.stringify(payload)).toString("base64url");
}

server.listen(PORT, "0.0.0.0", () => {
  console.log(`localbot agent on :${PORT}`);
  const code = shareCode();
  if (code) console.log(`Share code (grants control of this machine; keep it private):\n${code}`);
});
