import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { Conversations, type Workplace } from "../src/chat/conversations.ts";
import { Routines } from "../src/routines/routines.ts";
import { MemoryService } from "../src/memory/memory.ts";
import type { Bot } from "../src/bots/bots.ts";
import type { Hands } from "../src/hands/types.ts";
import { FakeProvider, sleep, type Step } from "./fake.ts";

// Tests in this file share one data dir, so every test gets fresh bot ids.
let run = 0;
const ids = () => { run++; return { a: `a${run}`, b: `b${run}` }; };
const mkBot = (id: string, name: string, role = ""): Bot =>
  ({ id, name, role, instructions: "", provider: "fake", model: "fake-1", avatarSeed: "s", createdAt: new Date().toISOString() });

/** A device that records actions and returns a 1×1 PNG as its screen. */
class FakeHands implements Hands {
  actions: string[] = [];
  describe() { return "Fake device"; }
  async screenshot() {
    return { png: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", width: 1, height: 1 };
  }
  async act(tool: string, args: Record<string, unknown>) { this.actions.push(`${tool} ${JSON.stringify(args)}`); return { effect: "ok" }; }
  async shell(command: string) { this.actions.push(`shell ${command}`); return { code: 0, output: "hello\n" }; }
}

/** Scripts are keyed "a"/"b"; they map to this test's fresh bot ids. */
function setup(scripts: Record<string, Step[]>, opts: { hands?: Hands; names?: [string, string?]; roles?: [string, string?] } = {}) {
  const events: { event: string; data: any }[] = [];
  const id = ids();
  const [na, nb] = opts.names ?? ["Alice", "Bob"];
  const [ra, rb] = opts.roles ?? ["", ""];
  const bots = [mkBot(id.a, na, ra), ...(nb ? [mkBot(id.b, nb, rb)] : [])];
  const fakes: Record<string, FakeProvider> = Object.fromEntries(
    Object.entries(scripts).map(([k, s]) => [k === "a" ? id.a : id.b, new FakeProvider(s)]),
  );
  const workplace = async (): Promise<Workplace | null> => (opts.hands ? { hands: opts.hands, computerName: "Linux" } : null);
  const conv = new Conversations((event, data) => events.push({ event, data }), workplace, () => bots, (bot) => fakes[bot.id]);
  return { conv, events, fakes: { a: fakes[id.a], b: fakes[id.b] }, bots, id };
}

/** Resolves once every bot is idle again. */
async function settle(conv: Conversations, bots: Bot[]) {
  await sleep(20);
  for (let i = 0; i < 500 && bots.some((b) => conv.isBusy(b.id)); i++) await sleep(10);
}

test("a plain reply is streamed and saved", async () => {
  const { conv, events, bots, id } = setup({ a: [{ text: "Olá!" }] });
  await conv.send(bots[0], "oi");
  await settle(conv, bots);
  const saved = conv.history(id.a);
  assert.deepEqual(saved.map((m) => [m.role, m.text]), [["user", "oi"], ["assistant", "Olá!"]]);
  assert.ok(events.some((e) => e.event === "message.delta" && e.data.delta === "Olá!"));
  assert.ok(events.some((e) => e.event === "bot.status" && e.data.status === "idle"));
});

test("device tools act on the device and a fresh screenshot follows", async () => {
  const hands = new FakeHands();
  const { conv, fakes, bots, id } = setup({
    a: [{ tools: [{ name: "click", args: { x: 10, y: 20 } }] }, { text: "Cliquei." }],
  }, { hands });
  await conv.send(bots[0], "clica ali");
  await settle(conv, bots);
  assert.equal(hands.actions.length, 1);
  assert.match(hands.actions[0], /^click /);
  assert.ok(conv.history(id.a).some((m) => m.role === "activity" && m.text === "Clicked at (10, 20)"));
  const second = fakes.a.requests[1].messages;
  assert.ok(second.some((m) => m.role === "user" && Array.isArray(m.content) && m.content.some((p) => p.type === "image_url")));
});

test("without a device, device tools aren't offered", async () => {
  const { conv, fakes, bots } = setup({ a: [{ text: "ok" }] });
  await conv.send(bots[0], "oi");
  await settle(conv, bots);
  const names = (fakes.a.requests[0].tools ?? []).map((t) => t.name);
  assert.ok(!names.includes("click"));
});

test("provider errors become plain-language messages with details kept", async () => {
  const { conv, fakes, bots, id } = setup({ a: [] });
  fakes.a.chat = async () => { throw new Error("OpenRouter returned 401: invalid api key"); };
  await conv.send(bots[0], "oi");
  await settle(conv, bots);
  const reply = conv.history(id.a).find((m) => m.role === "assistant")!;
  assert.match(reply.error!, /rejected the API key/);
  assert.match(reply.detail!, /401/);
});

test("ask_bot runs in the teammate's chat and returns its answer", async () => {
  const { conv, fakes, bots, id } = setup({
    a: [{ tools: [{ name: "ask_bot", args: { bot: "Matemático", message: "17 x 23?" } }] }, { text: "Deu 391." }],
    b: [{ text: "391" }],
  }, { names: ["Chefe", "Matemático"], roles: ["Coordena", "Contas"] });
  await conv.send(bots[0], "pergunta pro matemático");
  await settle(conv, bots);
  assert.deepEqual(conv.history(id.b).map((m) => [m.role, m.text, m.from?.name]), [["user", "17 x 23?", "Chefe"], ["assistant", "391", undefined]]);
  const toolResult = fakes.a.requests[1].messages.find((m) => m.role === "tool")!;
  assert.match(String(toolResult.content), /Matemático replied:\n391/);
  assert.ok(conv.history(id.a).some((m) => m.text.startsWith("Asked Matemático")));
});

test("ask_bot can't loop back to someone already in the chain", async () => {
  const { conv, fakes, bots, id } = setup({
    a: [{ tools: [{ name: "ask_bot", args: { bot: "Matemático", message: "pergunte ao Chefe" } }] }, { text: "fim" }],
    b: [(req) => ({ text: (req.tools ?? []).some((t) => t.name === "ask_bot") ? "tenho ask_bot" : "sem ask_bot" })],
  }, { names: ["Chefe", "Matemático"] });
  await conv.send(bots[0], "teste");
  await settle(conv, bots);
  assert.equal(conv.history(id.b).find((m) => m.role === "assistant")!.text, "sem ask_bot");
  assert.ok(fakes.b.requests.length === 1);
});

test("bots create, list and delete their own routines", async () => {
  const { conv, fakes, bots, id } = setup({
    a: [
      { tools: [{ name: "create_routine", args: { name: "Resumo", task: "Resuma as notícias", schedule: { kind: "daily", time: "08:00", days: [1, 2, 3, 4, 5] } } }] },
      { text: "Criada." },
      { tools: [{ name: "delete_routine", args: { name: "resumo" } }] },
      { text: "Apagada." },
    ],
  });
  const routines = new Routines(async () => ({ ok: true }), () => false, () => {});
  conv.attachRoutines(routines);
  await conv.send(bots[0], "todo dia útil às 8h, resume as notícias");
  await settle(conv, bots);
  assert.equal(routines.list(id.a)[0].scheduleText, "Weekdays at 08:00");
  assert.match(String(fakes.a.requests[1].messages.find((m) => m.role === "tool")!.content), /Created routine "Resumo"/);
  await conv.send(bots[0], "cancela");
  await settle(conv, bots);
  assert.equal(routines.list(id.a).length, 0);
});

test("memory tools are offered and remember saves", async () => {
  const { conv, bots, id } = setup({ a: [{ tools: [{ name: "remember", args: { text: "Usuário prefere português" } }] }, { text: "Anotado." }] });
  const memory = new MemoryService(async () => '{"episode":null,"ops":[]}', () => {});
  conv.attachMemory(memory);
  await conv.send(bots[0], "fala comigo em português");
  await settle(conv, bots);
  assert.ok(memory.store.list(id.a).some((m) => m.text === "Usuário prefere português"));
  assert.ok(conv.history(id.a).some((m) => m.role === "activity" && m.text.startsWith("Remembered:")));
});

test("stop aborts a running bot", async () => {
  const { conv, fakes, bots, id } = setup({ a: [] });
  fakes.a.chat = (req) => new Promise((_, reject) => req.signal?.addEventListener("abort", () => reject(new Error("aborted"))));
  await conv.send(bots[0], "demora");
  await sleep(30);
  assert.ok(conv.isBusy(id.a));
  conv.stop(id.a);
  await settle(conv, bots);
  assert.ok(!conv.isBusy(id.a));
});

test("a bot keeps working past many steps, and old tool outputs are shortened", async () => {
  class LongOutput extends FakeHands {
    override async shell(command: string) { this.actions.push(`shell ${command}`); return { code: 0, output: "x".repeat(2000) }; }
  }
  const hands = new LongOutput();
  const steps: Step[] = Array.from({ length: 45 }, (_, i) => ({ tools: [{ name: "shell", args: { command: `echo ${i}` } }] }));
  const { conv, fakes, bots, id } = setup({ a: [...steps, { text: "Pronto." }] }, { hands });
  await conv.send(bots[0], "faz tudo");
  await settle(conv, bots);
  assert.equal(hands.actions.length, 45);
  assert.equal(conv.history(id.a).at(-1)?.text, "Pronto.");
  const outputs = fakes.a.requests.at(-1)!.messages.filter((m) => m.role === "tool").map((m) => String(m.content));
  assert.equal(outputs.length, 45);
  assert.ok(outputs.slice(0, -20).every((o) => o.length < 400 && o.endsWith("(older output shortened)")));
  assert.ok(outputs.slice(-20).every((o) => o.length > 2000));
});
