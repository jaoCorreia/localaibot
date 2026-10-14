import { randomUUID } from "node:crypto";
import { Collection } from "../store.ts";
import { describe, nextRun, validate, type Schedule } from "./schedule.ts";

export interface Routine {
  id: string;
  botId: string;
  name: string;
  /** What the bot should do, in plain language. */
  task: string;
  schedule: Schedule;
  enabled: boolean;
  createdAt: string;
  nextRunAt: string | null;
  lastRunAt?: string;
  lastStatus?: "ok" | "failed" | "running" | "skipped";
  lastError?: string;
}

export type RoutineView = Routine & { scheduleText: string };

/** Result of one run, reported by whoever executes it. */
export interface RunOutcome {
  ok: boolean;
  error?: string;
  /** The bot's final reply text, when it finished with one. */
  reply?: string;
}

type Runner = (routine: Routine) => Promise<RunOutcome>;
type Busy = (botId: string) => boolean;

/** How often the scheduler wakes up to look for due routines. */
const TICK_MS = 30_000;

/**
 * Routines: tasks a bot runs on a schedule, on its own. The scheduler checks
 * every 30 s; a due routine waits while its bot is busy, and a run missed
 * while the app was closed happens once on startup (no backlog).
 */
export class Routines {
  private items = new Collection<Routine>("routines.json");
  private timer?: NodeJS.Timeout;

  constructor(private runner: Runner, private busy: Busy, private changed: () => void) {
    // Anything left "running" by a previous process didn't finish.
    for (const r of this.items.where((x) => x.lastStatus === "running")) {
      this.items.upsert({ ...r, lastStatus: "failed", lastError: "Interrupted (the app was closed)" });
    }
  }

  start() {
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    setTimeout(() => void this.tick(), 3_000);
  }

  stop() {
    clearInterval(this.timer);
  }

  list(botId?: string): RoutineView[] {
    return this.items
      .where((r) => !botId || r.botId === botId)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
      .map((r) => ({ ...r, scheduleText: describe(r.schedule) }));
  }

  create(input: { botId: string; name: string; task: string; schedule: Schedule; enabled?: boolean }): RoutineView {
    const name = input.name?.trim();
    const task = input.task?.trim();
    if (!name) throw new Error("The routine needs a name");
    if (!task) throw new Error("Describe what the bot should do");
    const schedule = validate(input.schedule);
    const routine: Routine = {
      id: randomUUID(),
      botId: input.botId,
      name,
      task,
      schedule,
      enabled: input.enabled ?? true,
      createdAt: new Date().toISOString(),
      nextRunAt: nextRun(schedule, new Date())?.toISOString() ?? null,
    };
    this.items.upsert(routine);
    this.changed();
    return { ...routine, scheduleText: describe(schedule) };
  }

  update(id: string, patch: Partial<Pick<Routine, "name" | "task" | "schedule" | "enabled">>): RoutineView {
    const current = this.get(id);
    const schedule = patch.schedule ? validate(patch.schedule) : current.schedule;
    const next: Routine = {
      ...current,
      ...patch,
      name: patch.name?.trim() || current.name,
      task: patch.task?.trim() || current.task,
      schedule,
    };
    // Re-plan whenever the schedule changes or the routine is switched on.
    if (patch.schedule || (patch.enabled && !current.enabled)) {
      next.nextRunAt = nextRun(schedule, new Date())?.toISOString() ?? null;
    }
    this.items.upsert(next);
    this.changed();
    return { ...next, scheduleText: describe(schedule) };
  }

  delete(id: string) {
    this.items.remove((r) => r.id === id);
    this.changed();
  }

  deleteForBot(botId: string) {
    this.items.remove((r) => r.botId === botId);
    this.changed();
  }

  /** Runs now, outside the schedule (the next scheduled run is unchanged). */
  async runNow(id: string) {
    const routine = this.get(id);
    if (this.busy(routine.botId)) throw new Error("The bot is busy right now");
    void this.execute(routine, false);
  }

  private get(id: string) {
    const r = this.items.get(id);
    if (!r) throw new Error(`Routine not found: ${id}`);
    return r;
  }

  private async tick() {
    const now = new Date();
    for (const r of this.items.where((x) => x.enabled && !!x.nextRunAt && x.lastStatus !== "running")) {
      if (new Date(r.nextRunAt!) > now) continue;
      if (this.busy(r.botId)) continue; // try again next tick
      void this.execute(r, true);
    }
  }

  private async execute(routine: Routine, scheduled: boolean) {
    const startedAt = new Date();
    this.items.upsert({ ...routine, lastStatus: "running", lastRunAt: startedAt.toISOString() });
    this.changed();

    let outcome: RunOutcome;
    try {
      outcome = await this.runner(routine);
    } catch (err) {
      outcome = { ok: false, error: err instanceof Error ? err.message : String(err) };
    }

    const latest = this.items.get(routine.id);
    if (!latest) return; // deleted while running
    const next = scheduled ? nextRun(latest.schedule, new Date(), startedAt) : latest.nextRunAt ? new Date(latest.nextRunAt) : null;
    this.items.upsert({
      ...latest,
      lastStatus: outcome.ok ? "ok" : "failed",
      lastError: outcome.error,
      nextRunAt: next?.toISOString() ?? null,
      // One-time routines switch themselves off once done.
      enabled: latest.schedule.kind === "once" && scheduled ? false : latest.enabled,
    });
    this.changed();
  }
}
