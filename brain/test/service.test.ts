import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { join } from "node:path";

const ENTRY = join(import.meta.dirname, "../src/index.ts");

/** A brain process speaking the JSON-lines protocol on stdio. */
function brain(...args: string[]) {
  const child = spawn(process.execPath, ["--import", "tsx", ENTRY, ...args], {
    env: { ...process.env, LOCALBOT_TAKEOVER_MS: "300", NODE_NO_WARNINGS: "1" },
  }) as ChildProcessWithoutNullStreams;
  const replies = new Map<number, (v: any) => void>();
  createInterface({ input: child.stdout }).on("line", (line) => {
    const msg = JSON.parse(line);
    if (msg.id !== undefined) replies.get(msg.id)?.(msg);
  });
  let next = 1;
  const call = (method: string, params = {}) =>
    new Promise<any>((resolve, reject) => {
      const id = next++;
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 15_000);
      replies.set(id, (m) => { clearTimeout(timer); m.error ? reject(new Error(m.error)) : resolve(m.result); });
      child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
  const exited = new Promise<number | null>((r) => child.on("exit", (code) => r(code)));
  return { child, call, exited };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("one brain owns the data: the service waits for the app's, takes over, and the next app attaches", { timeout: 60_000 }, async () => {
  const app = brain();
  const first = await app.call("app.info");
  assert.equal(first.service, false);

  // The service starts while the app's brain owns the data: it must wait.
  const svc = brain("--service");
  await sleep(1000);
  assert.equal(svc.child.exitCode, null);

  // The app quits: its brain exits and the service takes over.
  app.child.stdin.end();
  assert.equal(await app.exited, 0);
  await sleep(2000);

  // A new app's brain finds the service and bridges to it.
  const next = brain();
  const info = await next.call("app.info");
  assert.equal(info.service, true);
  assert.equal(info.pid, svc.child.pid);
  assert.ok(Array.isArray(await next.call("bots.list")));

  next.child.stdin.end();
  assert.equal(await next.exited, 0);
  // Closing the app leaves the service running.
  await sleep(300);
  assert.equal(svc.child.exitCode, null);
  svc.child.kill();
  await svc.exited;
});
