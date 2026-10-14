import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryStore } from "../src/memory/store.ts";
import { MemoryService } from "../src/memory/memory.ts";
import type { Bot } from "../src/bots/bots.ts";

const bot = { id: "b1", name: "Memo" } as Bot;

test("store: supersede keeps history; search is accent-insensitive", () => {
  const s = new MemoryStore(":memory:");
  const old = s.add({ botId: "b1", kind: "fact", text: "O cliente Acme assina plano mensal", source: "bot" });
  const now = s.supersede(old.id, "O cliente Acme agora só assina plano anual", "learned");
  assert.deepEqual(s.search("b1", "qual plano a acmé usa").map((m) => m.text), [now.text]);
  const history = s.list("b1", true).find((m) => m.id === old.id)!;
  assert.ok(history.validTo);
  assert.equal(history.supersededBy, now.id);
});

test("store: duplicates are merged, bots are isolated, team is shared", () => {
  const s = new MemoryStore(":memory:");
  const a = s.add({ botId: "b1", kind: "fact", text: "Gosta de café", source: "bot" });
  assert.equal(s.add({ botId: "b1", kind: "fact", text: "gosta de café", source: "bot" }).id, a.id);
  s.add({ botId: "b2", kind: "fact", text: "Segredo do outro bot", source: "bot" });
  s.add({ botId: null, kind: "core", text: "A empresa se chama YVY", source: "user" });
  assert.equal(s.search("b1", "segredo").length, 0);
  assert.equal(s.core("b1")[0].text, "A empresa se chama YVY");
  assert.equal(s.core("b2")[0].text, "A empresa se chama YVY");
});

test("store: forget hides, delete erases, core is capped", () => {
  const s = new MemoryStore(":memory:");
  const m = s.add({ botId: "b1", kind: "fact", text: "Temporário", source: "bot" });
  s.forget(m.id);
  assert.equal(s.search("b1", "temporário").length, 0);
  assert.ok(s.get(m.id));
  s.delete(m.id);
  assert.equal(s.get(m.id), undefined);
  for (let i = 0; i < 20; i++) s.add({ botId: "b1", kind: "core", text: `Regra ${i}`, source: "user" });
  assert.throws(() => s.add({ botId: "b1", kind: "core", text: "Uma a mais", source: "user" }), /full/);
});

test("service: remember / recall / forget tools, and secrets are refused", () => {
  const svc = new MemoryService(async () => "", () => {});
  const saved = svc.tool(bot, "remember", JSON.stringify({ text: "Prefere respostas curtas", kind: "core" }));
  assert.match(saved.result, /Saved as m-/);
  assert.match(svc.tool(bot, "recall", JSON.stringify({ query: "respostas" })).result, /Prefere respostas curtas/);
  assert.match(svc.tool(bot, "remember", JSON.stringify({ text: "senha: hunter2" })).result, /secret/);
  assert.match(svc.tool(bot, "remember", JSON.stringify({ text: "chave sk-or-v1-abcdefghijklmnop" })).result, /secret/);
  const id = /m-[0-9a-f]+/.exec(saved.result)![0];
  assert.match(svc.tool(bot, "forget", JSON.stringify({ id })).result, /Forgot/);
  assert.match(svc.context(bot, "respostas"), /Nothing saved yet/);
});

test("consolidation: adds learned facts, records the episode, ignores same-turn saves", async () => {
  let prompt = "";
  const svc = new MemoryService(async (_b, msgs) => {
    prompt = String(msgs[0].content);
    return 'Sure: {"episode":"Compared plans for the client","ops":[{"op":"add","kind":"fact","text":"Fazenda X fecha só contrato anual"}]}';
  }, () => {});
  const startedAt = new Date(Date.now() - 1000).toISOString();
  svc.tool(bot, "remember", JSON.stringify({ text: "Usuário se chama Patrick", kind: "core" }));
  await svc.consolidate(bot, { request: "compara os planos", steps: [], reply: "Feito", startedAt });
  assert.match(prompt, /Saved by the bot during this exchange[\s\S]*Patrick/);
  const all = svc.store.list("b1");
  assert.ok(all.some((m) => m.kind === "episode" && m.text === "Compared plans for the client"));
  assert.ok(all.some((m) => m.kind === "fact" && m.source === "learned"));
});

test("store: reset erases everything", () => {
  const s = new MemoryStore(":memory:");
  s.add({ botId: "b1", kind: "fact", text: "Algo para esquecer", source: "bot" });
  s.setChatSummary("b1", "resumo", new Date().toISOString());
  s.reset();
  assert.equal(s.list("b1", true).length, 0);
  assert.equal(s.search("b1", "esquecer").length, 0);
  assert.equal(s.chatSummary("b1"), undefined);
});
