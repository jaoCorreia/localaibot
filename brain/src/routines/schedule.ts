/**
 * When a routine runs. Times are local to the machine running the brain.
 */
export type Schedule =
  | { kind: "interval"; every: number; unit: "minutes" | "hours" }
  | { kind: "daily"; time: string; days: number[] } // "HH:MM"; days 0=Sun…6=Sat, empty = every day
  | { kind: "once"; at: string }; // ISO date-time

const DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function validate(s: Schedule): Schedule {
  switch (s?.kind) {
    case "interval": {
      const every = Math.max(1, Math.floor(Number(s.every) || 0));
      const unit = s.unit === "hours" ? "hours" : "minutes";
      if (unit === "minutes" && every < 5) throw new Error("Run at most every 5 minutes");
      return { kind: "interval", every, unit };
    }
    case "daily": {
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(s.time)) throw new Error("Time must be HH:MM");
      const days = [...new Set((s.days ?? []).map(Number).filter((d) => d >= 0 && d <= 6))].sort();
      return { kind: "daily", time: s.time, days };
    }
    case "once": {
      if (Number.isNaN(Date.parse(s.at))) throw new Error("Invalid date");
      return { kind: "once", at: new Date(s.at).toISOString() };
    }
    default:
      throw new Error("Unknown schedule");
  }
}

/** Next run strictly after `from`, or null when it will never run again. */
export function nextRun(s: Schedule, from: Date, lastRun?: Date): Date | null {
  switch (s.kind) {
    case "interval": {
      const ms = s.every * (s.unit === "hours" ? 3_600_000 : 60_000);
      const base = lastRun ?? from;
      const next = new Date(base.getTime() + ms);
      return next > from ? next : new Date(from.getTime() + ms);
    }
    case "daily": {
      const [h, m] = s.time.split(":").map(Number);
      for (let i = 0; i < 8; i++) {
        const d = new Date(from);
        d.setDate(d.getDate() + i);
        d.setHours(h, m, 0, 0);
        if (d > from && (s.days.length === 0 || s.days.includes(d.getDay()))) return d;
      }
      return null;
    }
    case "once": {
      // Planned only while in the future; a missed one-time run is caught up
      // by the scheduler from the stored nextRunAt, not re-planned here.
      const at = new Date(s.at);
      return lastRun || at <= from ? null : at;
    }
  }
}

export function describe(s: Schedule): string {
  switch (s.kind) {
    case "interval":
      return `Every ${s.every === 1 ? "" : `${s.every} `}${s.every === 1 ? s.unit.slice(0, -1) : s.unit}`;
    case "daily": {
      const days =
        s.days.length === 0 || s.days.length === 7 ? "Every day"
        : s.days.join() === "1,2,3,4,5" ? "Weekdays"
        : s.days.join() === "0,6" ? "Weekends"
        : s.days.map((d) => DAY[d]).join(", ");
      return `${days} at ${s.time}`;
    }
    case "once":
      return `Once, ${new Date(s.at).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })}`;
  }
}
