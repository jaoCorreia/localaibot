import { createInterface } from "node:readline";
import { events, invoke, log } from "./core.ts";

/**
 * Brain entry point for the local app. Protocol with the shell: one JSON
 * object per line on stdio.
 *   request  {id, method, params}  ->  {id, result} | {id, error}
 *   event    {event, data}          (brain -> shell, unsolicited)
 * stdout is reserved for the protocol; logs go to stderr.
 */
events.on("event", (event: string, data: unknown) => {
  process.stdout.write(JSON.stringify({ event, data }) + "\n");
});

const inFlight = new Set<Promise<void>>();
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const task = handle(line);
  inFlight.add(task);
  task.finally(() => inFlight.delete(task));
});
// The shell closing stdin means shutdown; finish in-flight requests first.
rl.on("close", async () => {
  await Promise.allSettled(inFlight);
  process.exit(0);
});

async function handle(line: string) {
  if (!line.trim()) return;
  let req: { id: number; method: string; params?: unknown };
  try {
    req = JSON.parse(line);
  } catch {
    return log("invalid line:", line);
  }
  const reply = (body: object) => process.stdout.write(JSON.stringify({ id: req.id, ...body }) + "\n");
  try {
    reply({ result: await invoke(req.method, req.params) });
  } catch (err) {
    reply({ error: err instanceof Error ? err.message : String(err) });
  }
}

log("ready");
