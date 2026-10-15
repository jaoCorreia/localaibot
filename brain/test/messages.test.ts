import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MessageStore } from "../src/chat/messages.ts";

const msg = (id: string, botId: string, text: string) => ({ id, botId, role: "user" as const, text, at: new Date().toISOString() });

test("messages.json is copied in once, in order, and left as it was", () => {
  const dir = mkdtempSync(join(tmpdir(), "localbot-msgs-"));
  writeFileSync(join(dir, "messages.json"), JSON.stringify([msg("1", "a", "one"), msg("2", "b", "two"), msg("3", "a", "three")]));
  const store = new MessageStore(dir);
  assert.deepEqual(store.forBot("a").map((m) => m.text), ["one", "three"]);
  assert.ok(existsSync(join(dir, "messages.json")));
  // Opening again doesn't import twice.
  assert.equal(new MessageStore(dir).forBot("a").length, 2);
});

test("pages go back from the newest; updates keep their place", () => {
  const store = new MessageStore(mkdtempSync(join(tmpdir(), "localbot-msgs-")));
  for (let i = 1; i <= 7; i++) store.upsert(msg(`m${i}`, "bot", `t${i}`));
  store.upsert(msg("other", "x", "elsewhere"));

  const last = store.page("bot", 3);
  assert.deepEqual(last.messages.map((m) => m.text), ["t5", "t6", "t7"]);
  assert.equal(last.more, true);
  const earlier = store.page("bot", 3, "m5");
  assert.deepEqual(earlier.messages.map((m) => m.text), ["t2", "t3", "t4"]);
  const first = store.page("bot", 3, "m2");
  assert.deepEqual(first.messages.map((m) => m.text), ["t1"]);
  assert.equal(first.more, false);

  // A card that changes state stays where it was.
  store.upsert({ ...msg("m3", "bot", "t3 edited") });
  assert.deepEqual(store.forBot("bot").map((m) => m.text), ["t1", "t2", "t3 edited", "t4", "t5", "t6", "t7"]);
  store.removeBot("bot");
  assert.deepEqual(store.forBot("bot"), []);
  assert.equal(store.forBot("x").length, 1);
});
