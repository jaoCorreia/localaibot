import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { Routines } from "../src/routines/routines.ts";
import { sleep } from "./fake.ts";

test("create validates and plans the next run", () => {
  const r = new Routines(async () => ({ ok: true }), () => false, () => {});
  assert.throws(() => r.create({ botId: "bot1", name: "", task: "x", schedule: { kind: "interval", every: 1, unit: "hours" } }), /name/);
  const made = r.create({ botId: "bot1", name: "Hourly", task: "check", schedule: { kind: "interval", every: 1, unit: "hours" } });
  assert.ok(made.nextRunAt && Date.parse(made.nextRunAt) > Date.now());
  assert.equal(made.scheduleText, "Every hour");
});

test("a due one-time routine runs once, then switches off", async () => {
  // (each test uses its own bot id: tests here share one data dir)
  let runs = 0;
  const r = new Routines(async () => { runs++; return { ok: true, reply: "done" }; }, () => false, () => {});
  const made = r.create({ botId: "bot2", name: "Soon", task: "x", schedule: { kind: "once", at: new Date(Date.now() + 50).toISOString() } });
  await sleep(80);
  await (r as any).tick();
  await sleep(20);
  const after = r.list("bot2").find((x) => x.id === made.id)!;
  assert.equal(runs, 1);
  assert.equal(after.lastStatus, "ok");
  assert.equal(after.enabled, false);
  await (r as any).tick();
  assert.equal(runs, 1);
});

test("a busy bot defers its routine; failures are recorded", async () => {
  let busy = true;
  const r = new Routines(async () => ({ ok: false, error: "The device is off." }), () => busy, () => {});
  const made = r.create({ botId: "bot3", name: "Soon", task: "x", schedule: { kind: "once", at: new Date(Date.now() + 20).toISOString() } });
  await sleep(40);
  await (r as any).tick();
  assert.equal(r.list("bot3")[0].lastStatus, undefined);
  busy = false;
  await (r as any).tick();
  await sleep(20);
  const after = r.list("bot3").find((x) => x.id === made.id)!;
  assert.equal(after.lastStatus, "failed");
  assert.equal(after.lastError, "The device is off.");
});

test("runNow keeps the schedule; deleteForBot cleans up", async () => {
  const r = new Routines(async () => ({ ok: true }), () => false, () => {});
  const made = r.create({ botId: "bot4", name: "Daily", task: "x", schedule: { kind: "daily", time: "09:00", days: [] } });
  await r.runNow(made.id);
  await sleep(20);
  const after = r.list("bot4")[0];
  assert.equal(after.lastStatus, "ok");
  assert.equal(after.nextRunAt, made.nextRunAt);
  r.deleteForBot("bot4");
  assert.equal(r.list("bot4").length, 0);
});
