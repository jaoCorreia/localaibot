import { createInterface } from "node:readline";
import { avatarOptions, avatarSVG, randomAvatar } from "./bots/avatar.ts";
import { Bots } from "./bots/bots.ts";
import { Conversations } from "./chat/conversations.ts";
import { addProvider, initProviders, provider, providerStatus, removeProvider, setDefault, settings, testProvider, updateProvider } from "./chat/providers.ts";
import { DockerProvider } from "./computers/docker.ts";
import { LumeProvider } from "./computers/lume.ts";
import { Routines } from "./routines/routines.ts";
import { MemoryService } from "./memory/memory.ts";
import { Collection } from "./store.ts";
import type { ComputerProvider } from "./computers/types.ts";

/**
 * Brain entry point. Protocol with the shell: one JSON object per line on stdio.
 *   request  {id, method, params}  ->  {id, result} | {id, error}
 *   event    {event, data}          (brain -> shell, unsolicited)
 * stdout is reserved for the protocol; logs go to stderr.
 */
const computerProviders: ComputerProvider[] = [new DockerProvider(), new LumeProvider()];

function emit(event: string, data: unknown) {
  process.stdout.write(JSON.stringify({ event, data }) + "\n");
}

const log = (...args: unknown[]) => console.error("[brain]", ...args);

function computerProvider(id: string) {
  const p = computerProviders.find((x) => id.startsWith(`${x.name}:`));
  if (!p) throw new Error(`Unknown device: ${id}`);
  return p;
}

const bots = new Bots();

/**
 * Display names chosen by the user. Kept here rather than on the device:
 * Docker labels can't change after a container is created, and Lume names
 * are folder names.
 */
const deviceNames = new Collection<{ id: string; name: string }>("device-names.json");
const named = <T extends { id: string; name: string }>(c: T): T => ({ ...c, name: deviceNames.get(c.id)?.name ?? c.name });

/** A bot works on its own computer first, then on any computer it was granted. */
const conversations = new Conversations(emit, async (bot) => {
  const view = bots.list().find((b) => b.id === bot.id);
  const accesses = [...(view?.computers ?? [])].sort((a, b) => (a.role === "owner" ? -1 : b.role === "owner" ? 1 : 0));
  for (const access of accesses) {
    const p = computerProvider(access.computerId);
    const hands = await p.hands?.(access.computerId, `bot-${bot.id.slice(0, 8)}`);
    if (!hands) continue;
    const computer = (await p.list()).find((c) => c.id === access.computerId);
    return { hands, computerName: computer ? named(computer).name : access.computerId };
  }
  return null;
}, () => bots.list());

const botsChanged = () => emit("bots", null);

/** Scheduled tasks: each run is a turn in the bot's chat. */
const routines = new Routines(
  (routine) => conversations.runRoutine(bots.get(routine.botId), routine),
  (botId) => conversations.isBusy(botId),
  () => emit("routines", null),
);
conversations.attachRoutines(routines);

/** Long-term memory; consolidation and summaries use each bot's own model. */
const memory = new MemoryService(
  async (bot, messages) =>
    (await provider(bot.provider).chat({ model: bot.model, messages, onDelta: () => {} })).text,
  (botId) => emit("memory", { botId }),
);
conversations.attachMemory(memory);
// Started once keys are loaded (see `ready` below).

type Handler = (params: any) => unknown | Promise<unknown>;

const methods: Record<string, Handler> = {
  // Computers
  "computers.list": async () => {
    const usable = await Promise.all(computerProviders.map(async (p) => ((await p.available()) ? p : null)));
    const lists = await Promise.all(usable.filter((p): p is ComputerProvider => !!p).map((p) => p.list()));
    return lists.flat().map((c) => ({ ...named(c), bots: bots.botsOn(c.id) }));
  },
  /** What kinds of device can be added on this host (and what is coming). */
  "computers.kinds": async () => {
    const [docker, lume] = await Promise.all(computerProviders.map((p) => p.available()));
    return [
      { id: "docker", label: "Linux desktop", detail: "Debian + XFCE + Firefox in a container. Starts in seconds, ~1 GB.", available: docker, reason: docker ? null : "Docker isn’t running" },
      { id: "lume", label: "macOS virtual machine", detail: "Full macOS via Apple Virtualization. ~17 GB download, 8 GB RAM; up to 2 running per Mac.", available: lume, reason: lume ? null : "Needs an Apple silicon Mac" },
      { id: "ios-simulator", label: "iOS Simulator", detail: "Drive iPhone and iPad apps.", available: false, reason: "Coming soon" },
      { id: "android-emulator", label: "Android Emulator", detail: "Drive Android apps.", available: false, reason: "Coming soon" },
      { id: "remote", label: "Another computer", detail: "Pair a Mac, Windows or Linux machine over the network.", available: false, reason: "Coming soon" },
    ];
  },
  "computers.create": async ({ kind, name }) => {
    const p = computerProviders.find((x) => x.name === kind);
    if (!p?.create) throw new Error(`Can’t create ${kind} devices yet`);
    if (!String(name ?? "").trim()) throw new Error("The device needs a name");
    const id = await p.create(String(name).trim());
    emit("computers", null);
    return { id };
  },
  "computers.rename": ({ id, name }) => {
    const clean = String(name ?? "").trim();
    if (!clean) throw new Error("The device needs a name");
    if (clean.length > 40) throw new Error("Keep the name under 40 characters");
    computerProvider(id);
    deviceNames.upsert({ id, name: clean });
    emit("computers", null);
  },
  "computers.remove": async ({ id }) => {
    deviceNames.remove((d) => d.id === id);
    const p = computerProvider(id);
    if (!p.remove) throw new Error(`${p.name} devices can’t be removed from here`);
    await p.remove(id);
    for (const bot of bots.list()) bots.revoke(bot.id, id);
    emit("computers", null);
    botsChanged();
  },
  "computers.start": async ({ id }) => {
    const p = computerProvider(id);
    if (!p.start) throw new Error(`${p.name} devices are started by the app`);
    await p.start(id);
    emit("computers", null);
  },
  "computers.stop": async ({ id }) => {
    const p = computerProvider(id);
    if (!p.stop) throw new Error(`${p.name} devices are stopped by the app`);
    await p.stop(id);
    emit("computers", null);
  },

  // Bots
  "bots.list": () => bots.list().map((b) => ({ ...b, status: conversations.isBusy(b.id) ? "thinking" : "idle" })),
  "bots.create": (p) => {
    const bot = bots.create({
      ...p,
      provider: p.provider || settings.value.defaultProvider,
      model: p.model || settings.value.defaultModel,
    });
    botsChanged();
    return bot;
  },
  "bots.update": ({ id, ...patch }) => {
    const bot = bots.update(id, patch);
    botsChanged();
    return bot;
  },
  "bots.previewAvatar": ({ seed }) => avatarSVG(String(seed)),
  /** Every catalog option rendered on top of the given face (for the picker). */
  "bots.avatarOptions": ({ value }) => avatarOptions(String(value || randomAvatar())),
  "bots.randomAvatar": () => randomAvatar(),
  "bots.regenerateAvatar": ({ id }) => {
    const bot = bots.regenerateAvatar(id);
    botsChanged();
    return bot;
  },
  "bots.delete": ({ id }) => {
    conversations.clear(id);
    routines.deleteForBot(id);
    memory.store.deleteForBot(id);
    bots.delete(id);
    botsChanged();
  },

  // Access between bots and computers
  "access.grant": (p) => {
    const access = bots.grant({ grantedBy: "user", ...p });
    botsChanged();
    return access;
  },
  "access.revoke": ({ botId, computerId }) => {
    bots.revoke(botId, computerId);
    botsChanged();
  },

  // Memory
  "memory.list": ({ botId, history }) => memory.store.list(botId, !!history),
  "memory.add": ({ botId, kind, text, topic, scope }) => {
    bots.get(botId);
    const m = memory.store.add({ botId: scope === "team" ? null : botId, kind: kind ?? "fact", text, topic, source: "user" });
    emit("memory", { botId });
    return m;
  },
  "memory.edit": ({ id, botId, ...patch }) => {
    const m = memory.store.edit(id, patch);
    emit("memory", { botId });
    return m;
  },
  "memory.forget": ({ id, botId }) => {
    memory.store.forget(id);
    emit("memory", { botId });
  },
  "memory.delete": ({ id, botId }) => {
    memory.store.delete(id);
    emit("memory", { botId });
  },
  "memory.summary": ({ botId }) => memory.store.chatSummary(botId) ?? null,

  // Routines
  "routines.list": ({ botId }) => routines.list(botId),
  "routines.create": (p) => {
    bots.get(p.botId);
    return routines.create(p);
  },
  "routines.update": ({ id, ...patch }) => routines.update(id, patch),
  "routines.delete": ({ id }) => routines.delete(id),
  "routines.runNow": ({ id }) => routines.runNow(id),

  // Chat
  "chat.history": ({ botId }) => conversations.history(botId),
  "chat.send": ({ botId, text }) => conversations.send(bots.get(botId), text),
  "chat.stop": ({ botId }) => conversations.stop(botId),
  "chat.clear": ({ botId }) => conversations.clear(botId),

  // Conversation providers (keys never leave the brain)
  "providers.status": () => providerStatus(),
  "providers.add": async (p) => {
    const id = await addProvider(p);
    emit("providers", null);
    return { id, ...providerStatus() };
  },
  "providers.update": async ({ id, ...patch }) => {
    await updateProvider(id, patch);
    emit("providers", null);
    return providerStatus();
  },
  "providers.remove": async ({ id }) => {
    await removeProvider(id);
    emit("providers", null);
    return providerStatus();
  },
  "providers.test": ({ id }) => testProvider(id),
  "providers.models": ({ provider: id }) => provider(id ?? settings.value.defaultProvider).models(),
  "providers.setDefault": ({ provider: id, model }) => {
    setDefault(id, model);
    emit("providers", null);
    return providerStatus();
  },

  ping: () => "pong",
};

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

/** Keys load from the Keychain before the first request is served. */
const ready = initProviders()
  .catch((err) => log("couldn’t load keys:", err instanceof Error ? err.message : err))
  .then(() => routines.start());

async function handle(line: string) {
  if (!line.trim()) return;
  await ready;
  let req: { id: number; method: string; params?: unknown };
  try {
    req = JSON.parse(line);
  } catch {
    return log("invalid line:", line);
  }
  const reply = (body: object) => process.stdout.write(JSON.stringify({ id: req.id, ...body }) + "\n");
  const handler = methods[req.method];
  try {
    if (!handler) throw new Error(`Unknown method: ${req.method}`);
    reply({ result: (await handler(req.params ?? {})) ?? null });
  } catch (err) {
    reply({ error: err instanceof Error ? err.message : String(err) });
  }
}

log("ready");
