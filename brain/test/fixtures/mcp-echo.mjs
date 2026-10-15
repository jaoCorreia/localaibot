// A tiny MCP server over stdio for tests: one "echo" tool and one that fails.
import { createInterface } from "node:readline";
const send = (m) => process.stdout.write(JSON.stringify(m) + "\n");
createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.id === undefined) return;
  if (msg.method === "initialize") return send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "echo", version: "1" } } });
  if (msg.method === "tools/list") return send({ jsonrpc: "2.0", id: msg.id, result: { tools: [
    { name: "echo", description: "Repeats text", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
    { name: "boom", description: "Always fails", inputSchema: { type: "object", properties: {} } },
  ] } });
  if (msg.method === "tools/call") {
    const { name, arguments: args } = msg.params;
    if (name === "echo") return send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: `echo: ${args.text} (${process.env.ECHO_PREFIX ?? ""})` }] } });
    return send({ jsonrpc: "2.0", id: msg.id, result: { isError: true, content: [{ type: "text", text: "boom" }] } });
  }
  send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unknown method" } });
});
