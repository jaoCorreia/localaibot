import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { describe as describeSchedule, nextRun, validate } from "../src/routines/schedule.ts";

test("validate rejects bad input", () => {
  assert.throws(() => validate({ kind: "interval", every: 2, unit: "minutes" }), /5 minutes/);
  assert.throws(() => validate({ kind: "daily", time: "25:00", days: [] }), /HH:MM/);
  assert.throws(() => validate({ kind: "once", at: "not a date" }), /Invalid date/);
  assert.throws(() => validate({ kind: "weekly" } as any), /Unknown schedule/);
});

test("validate normalizes days and units", () => {
  assert.deepEqual(validate({ kind: "daily", time: "09:00", days: [5, 1, 1, 9 as any] }), { kind: "daily", time: "09:00", days: [1, 5] });
  assert.deepEqual(validate({ kind: "interval", every: 30, unit: "weird" as any }), { kind: "interval", every: 30, unit: "minutes" });
});

test("daily: next matching weekday at the given time", () => {
  const monday = new Date(2026, 9, 12, 10, 0); // Mon Oct 12 2026, 10:00 local
  const next = nextRun({ kind: "daily", time: "09:00", days: [1, 2, 3, 4, 5] }, monday)!;
  assert.equal(next.getDay(), 2); // already past 09:00 Monday → Tuesday
  assert.equal(next.getHours(), 9);
  const friday = new Date(2026, 9, 16, 10, 0);
  assert.equal(nextRun({ kind: "daily", time: "09:00", days: [1, 2, 3, 4, 5] }, friday)!.getDay(), 1); // skips weekend
  const early = new Date(2026, 9, 12, 8, 0);
  assert.equal(nextRun({ kind: "daily", time: "09:00", days: [] }, early)!.getDate(), 12); // same day
});

test("interval: from the last run, never in the past", () => {
  const now = new Date(2026, 9, 12, 10, 0);
  assert.equal(nextRun({ kind: "interval", every: 2, unit: "hours" }, now)!.getTime(), now.getTime() + 2 * 3_600_000);
  const longAgo = new Date(2026, 9, 1);
  assert.ok(nextRun({ kind: "interval", every: 30, unit: "minutes" }, now, longAgo)! > now);
});

test("once: only in the future, and only before it ran", () => {
  const now = new Date(2026, 9, 12, 10, 0);
  const later = new Date(2026, 9, 12, 15, 0);
  assert.equal(nextRun({ kind: "once", at: later.toISOString() }, now)!.getTime(), later.getTime());
  assert.equal(nextRun({ kind: "once", at: later.toISOString() }, now, now), null);
  assert.equal(nextRun({ kind: "once", at: new Date(2026, 9, 11).toISOString() }, now), null);
});

test("describe reads naturally", () => {
  assert.equal(describeSchedule({ kind: "daily", time: "08:00", days: [1, 2, 3, 4, 5] }), "Weekdays at 08:00");
  assert.equal(describeSchedule({ kind: "daily", time: "08:00", days: [] }), "Every day at 08:00");
  assert.equal(describeSchedule({ kind: "interval", every: 1, unit: "hours" }), "Every hour");
  assert.equal(describeSchedule({ kind: "interval", every: 15, unit: "minutes" }), "Every 15 minutes");
});
