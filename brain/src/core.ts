import { EventEmitter } from "node:events";
import { avatarOptions, avatarSVG, randomAvatar } from "./bots/avatar.ts";
import { Bots } from "./bots/bots.ts";
import { Conversations } from "./chat/conversations.ts";
import { addProvider, exportProvider, findProvider, initProviders, provider, providerStatus, removeProvider, resetProviders, setDefault, settings, testProvider, updateProvider } from "./chat/providers.ts";
import { DockerProvider } from "./computers/docker.ts";
import { LumeProvider } from "./computers/lume.ts";
import { RailwayProvider } from "./computers/railway.ts";
import { RemoteProvider } from "./computers/remote.ts";
import { Routines } from "./routines/routines.ts";
import { MemoryService } from "./memory/memory.ts";
import { Collection } from "./store.ts";
import { CloudLink } from "./cloud/link.ts";
import type { ComputerProvider } from "./computers/types.ts";

/**
 * The brain: bots, chats, devices, memory, routines, and the methods a shell
 * calls. Transports wrap it: stdio for the local app (index.ts), HTTP for a
 * brain running in the cloud (server.ts).
 *   request  {method, params}  ->  result | error
 *   event    {event, data}      (brain -> shell, unsolicited)
 * Logs go to stderr.
 */
/** macOS VMs (Lume) aren't part of the first release yet; LOCALBOT_EXPERIMENTAL_MACOS=1 turns them on. */
const macOSDevices = process.env.LOCALBOT_EXPERIMENTAL_MACOS === "1";
const docker = new DockerProvider();
const lume = macOSDevices ? new LumeProvider() : null;
const railway = new RailwayProvider();
const remoteDevices = new RemoteProvider();
const computerProviders: ComputerProvider[] = [docker, ...(lume ? [lume] : []), railway, remoteDevices];

/** Every event for the shell; each transport subscribes to "event". */
export const events = new EventEmitter();
events.setMaxListeners(0);

function emit(event: string, data: unknown) {
  events.emit("event", event, data);
}

export const log = (...args: unknown[]) => console.error("[brain]", ...args);

function computerProvider(id: string) {
  const p = computerProviders.find((x) => id.startsWith(`${x.name}:`));
  if (!p) throw new Error(`Unknown device: ${id}`);
  return p;
}

const bots = new Bots();

/** The brain in the cloud, if any: bots hosted there run while the Mac is off. */
const cloud = new CloudLink((event, data) => emit(event, data), log);

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

export type Handler = (params: any) => unknown | Promise<unknown>;

export const methods: Record<string, Handler> = {
  // Computers
  "computers.list": async () => {
    const usable = await Promise.all(computerProviders.map(async (p) => ((await p.available()) ? p : null)));
    const lists = await Promise.all(usable.filter((p): p is ComputerProvider => !!p).map((p) => p.list()));
    return lists.flat().map((c) => ({ ...named(c), bots: bots.botsOn(c.id) }));
  },
  /** What kinds of device can be added on this host (and what is coming). */
  "computers.kinds": async () => {
    const [dockerUp, lumeUp] = await Promise.all([docker.available(), lume?.available() ?? false]);
    return [
      { id: "docker", label: "Linux desktop", detail: "Debian + XFCE + Firefox in a container. Starts in seconds, ~1 GB.", available: dockerUp, reason: dockerUp ? null : "Docker isn’t running" },
      { id: "lume", label: "macOS virtual machine", detail: "Full macOS via Apple Virtualization. ~17 GB download, 8 GB RAM; up to 2 running per Mac.", available: lumeUp, reason: lumeUp ? null : "Coming soon" },
      {
        id: "railway", label: "Linux in the cloud", detail: "The same desktop on your Railway account. Keeps working while your Mac sleeps; billed by Railway.",
        available: railway.configured, reason: railway.configured ? null : "Connect Railway in Settings",
      },
      {
        id: "remote", label: "Connect a machine", detail: "Paste the share code of a device someone shared, or of your own server running the device image.",
        available: true, reason: null,
        fields: [
          { id: "code", label: "Share code", placeholder: "localbot-device:…", secure: true },
        ],
      },
      { id: "ios-simulator", label: "iOS Simulator", detail: "Drive iPhone and iPad apps.", available: false, reason: "Coming soon" },
      { id: "android-emulator", label: "Android Emulator", detail: "Drive Android apps.", available: false, reason: "Coming soon" },
    ];
  },
  "computers.create": async ({ kind, name, options }) => {
    const p = computerProviders.find((x) => x.name === kind);
    if (!p?.create) throw new Error(`Can’t create ${kind} devices yet`);
    if (!String(name ?? "").trim()) throw new Error("The device needs a name");
    const id = await p.create(String(name).trim(), options ?? {});
    emit("computers", null);
    return { id };
  },
  /** A string another Local Bot pastes into "Connect a machine". */
  "computers.share": async ({ id }) => {
    const p = computerProvider(id);
    if (!p.share) throw new Error("Only remote and cloud devices can be shared; this one lives on your Mac");
    return { code: await p.share(id) };
  },
  // Accounts of cloud device providers (Settings → Device providers)
  "deviceProviders.status": () => [railway.account],
  "deviceProviders.connect": async ({ id, token }) => {
    if (id !== railway.name) throw new Error(`Unknown device provider: ${id}`);
    await railway.setToken(String(token ?? ""));
    emit("computers", null);
    return [railway.account];
  },
  "deviceProviders.disconnect": async ({ id }) => {
    if (id !== railway.name) throw new Error(`Unknown device provider: ${id}`);
    await railway.disconnect();
    emit("computers", null);
    return [railway.account];
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

  /**
   * Back to a fresh install: bots, chats, memory, routines, providers and their
   * Keychain keys. Linux devices (containers) are removed only if asked.
   */
  "app.reset": async ({ removeDevices }) => {
    conversations.reset();
    routines.reset();
    memory.store.reset();
    bots.reset();
    await resetProviders();
    deviceNames.remove(() => true);
    if (removeDevices) {
      for (const p of computerProviders) {
        if (!p.remove || !(await p.available())) continue;
        for (const c of await p.list()) await p.remove(c.id).catch((err) => log("couldn’t remove", c.id, err?.message));
      }
    }
    emit("bots", null);
    emit("computers", null);
    emit("providers", null);
    emit("routines", null);
  },

  ping: () => "pong",
};


// ---------------------------------------------------------------- moving bots

/** Everything a bot is, to move it to another brain: config, grants, chat, routines, memory. */
function exportBundle(id: string) {
  const { bot, accesses } = bots.exportBot(id);
  return {
    version: 1,
    bot,
    accesses,
    messages: conversations.history(id),
    routines: routines.list(id).map(({ scheduleText, ...r }) => r),
    memory: memory.store.exportForBot(id),
  };
}
type Bundle = ReturnType<typeof exportBundle>;

function importBundle(b: Bundle) {
  if (b?.version !== 1 || !b.bot?.id) throw new Error("That bot export is from a different Local Bot");
  const view = bots.importBot(b.bot, b.accesses ?? []);
  conversations.importHistory(b.bot.id, b.messages ?? []);
  routines.importForBot(b.bot.id, b.routines ?? []);
  memory.store.importForBot(b.bot.id, b.memory ?? { rows: [], summary: null });
  botsChanged();
  emit("memory", { botId: b.bot.id });
  return view;
}

/** Drops a bot's data here (after it moved elsewhere); its devices stay. */
function forgetBot(id: string) {
  conversations.clear(id);
  routines.deleteForBot(id);
  memory.store.deleteForBot(id);
  bots.delete(id);
}

/** Registers a local device with the cloud brain (as a remote device) and returns its id there. */
async function cloudDeviceFor(localId: string) {
  const known = cloud.cloudDevice(localId);
  if (known) return known;
  const p = computerProvider(localId);
  if (!p.share) {
    const name = (await p.list()).find((c) => c.id === localId)?.name ?? localId;
    throw new Error(`“${named({ id: localId, name }).name}” runs on this Mac, so the cloud can’t reach it. Give the bot a cloud device first.`);
  }
  const name = named({ id: localId, name: (await p.list()).find((c) => c.id === localId)?.name ?? "Device" }).name;
  const { id } = (await cloud.call("computers.create", { kind: "remote", name, options: { code: await p.share(localId) } })) as { id: string };
  cloud.mapDevice(localId, id);
  return id;
}

/** The cloud brain's provider matching this one, set up there (with its key) if missing. */
async function cloudProviderFor(localId: string) {
  const config = exportProvider(localId);
  const status = (await cloud.call("providers.status")) as { providers: { id: string; preset: string; baseURL: string }[] };
  const same = status.providers.find((p) => p.preset === config.preset && p.baseURL === config.baseURL);
  if (same) return same.id;
  return ((await cloud.call("providers.add", config)) as { id: string }).id;
}

async function moveToCloud(botId: string) {
  if (!cloud.connected) throw new Error("Set up a cloud brain first (Settings → Device Providers)");
  if (conversations.isBusy(botId)) throw new Error("The bot is working; try again when it’s done");
  const bundle = exportBundle(botId);
  const accesses = [];
  for (const a of bundle.accesses) accesses.push({ ...a, computerId: await cloudDeviceFor(a.computerId) });
  const providerId = await cloudProviderFor(bundle.bot.provider);
  await cloud.call("bots.import", { bundle: { ...bundle, bot: { ...bundle.bot, provider: providerId }, accesses } });
  cloud.markHosted(botId, true);
  forgetBot(botId);
  botsChanged();
  emit("routines", null);
}

async function moveToMac(botId: string) {
  const bundle = (await cloud.call("bots.export", { id: botId })) as Bundle;
  const accesses = bundle.accesses
    .map((a) => cloud.toLocalAccess(a))
    .filter((a) => computerProviders.some((p) => a.computerId.startsWith(`${p.name}:`)));
  // Same service and URL here, or the default provider.
  const remoteProvider = (((await cloud.call("providers.status")) as any).providers as any[]).find((p) => p.id === bundle.bot.provider);
  const providerId = (remoteProvider && findProvider(remoteProvider.preset, remoteProvider.baseURL)) || settings.value.defaultProvider;
  importBundle({ ...bundle, bot: { ...bundle.bot, provider: providerId }, accesses });
  await cloud.call("bots.delete", { id: botId });
  cloud.markHosted(botId, false);
  botsChanged();
  emit("routines", null);
}

Object.assign(methods, {
  "bots.export": ({ id }) => exportBundle(id),
  "bots.import": ({ bundle }) => importBundle(bundle),

  "cloud.status": async () => ({
    connected: cloud.connected,
    url: cloud.url ?? null,
    managed: cloud.railwayServiceId ? "railway" : null,
    healthy: cloud.connected ? await cloud.health() : false,
    bots: cloud.hostedCount(),
  }),
  /** Creates a brain service on the connected Railway account and links it. */
  "cloud.setupRailway": async () => {
    if (cloud.connected) throw new Error("A cloud brain is already connected");
    const brain = await railway.createBrain();
    // The service takes a minute or two to come up; wait for it before linking.
    const deadline = Date.now() + 8 * 60_000;
    while (Date.now() < deadline) {
      try {
        await cloud.connect(brain.url, brain.token, brain.serviceId);
        emit("cloud", null);
        return { url: brain.url };
      } catch {
        await new Promise((r) => setTimeout(r, 5000));
      }
    }
    throw new Error("The cloud brain didn’t start in time; check the Local Bot project on Railway");
  },
  /** Links a brain someone runs elsewhere (brain/Dockerfile on any host). */
  "cloud.connect": async ({ url, token }) => {
    await cloud.connect(String(url ?? ""), String(token ?? ""));
    emit("cloud", null);
    botsChanged();
  },
  "cloud.disconnect": async ({ deleteBrain }) => {
    if (cloud.hostedCount()) throw new Error("Move the cloud bots back to this Mac first");
    const serviceId = cloud.railwayServiceId;
    if (deleteBrain && serviceId) await railway.deleteService(serviceId);
    await cloud.disconnect();
    emit("cloud", null);
  },
  "cloud.moveBot": async ({ botId, to }) => (to === "mac" ? moveToMac(botId) : moveToCloud(botId)),
} satisfies Record<string, Handler>);

// ---------------------------------------------------------------- forwarding

/**
 * Methods about a hosted bot go to the cloud brain. `key` names the param
 * that holds the bot id; device ids in params and results are translated.
 */
const botScoped: Record<string, string> = {
  "bots.update": "id", "bots.regenerateAvatar": "id",
  "memory.list": "botId", "memory.add": "botId", "memory.edit": "botId", "memory.forget": "botId",
  "memory.delete": "botId", "memory.summary": "botId",
  "routines.list": "botId", "routines.create": "botId",
  "chat.history": "botId", "chat.send": "botId", "chat.stop": "botId", "chat.clear": "botId",
  "access.grant": "botId", "access.revoke": "botId",
};

for (const [method, key] of Object.entries(botScoped)) {
  const local = methods[method];
  methods[method] = async (params: any) => {
    if (!cloud.isHosted(params?.[key])) return local(params);
    const p = { ...params };
    if (p.computerId) p.computerId = await cloudDeviceFor(p.computerId);
    const result: any = await cloud.call(method, p);
    return result?.computers ? { ...result, host: "cloud", computers: result.computers.map((a: any) => cloud.toLocalAccess(a)) } : result;
  };
}

// Routine methods name only the routine: try here, then the cloud.
for (const method of ["routines.update", "routines.delete", "routines.runNow"]) {
  const local = methods[method];
  methods[method] = async (params: any) => {
    try {
      return await local(params);
    } catch (err) {
      if (!cloud.connected || !/Routine not found/.test(err instanceof Error ? err.message : "")) throw err;
      return cloud.call(method, params);
    }
  };
}

{
  const localList = methods["bots.list"];
  methods["bots.list"] = async (params) => [...((await localList(params)) as any[]), ...(await cloud.bots())];
  const localDelete = methods["bots.delete"];
  methods["bots.delete"] = async (params: any) => {
    if (!cloud.isHosted(params?.id)) return localDelete(params);
    await cloud.call("bots.delete", params);
    cloud.markHosted(params.id, false);
    botsChanged();
  };
  // A hosted bot's devices also have ids in the cloud; drop that link when one goes away.
  const localRemove = methods["computers.remove"];
  methods["computers.remove"] = async (params: any) => {
    const cloudId = cloud.cloudDevice(params?.id);
    if (cloudId) {
      await cloud.call("computers.remove", { id: cloudId }).catch((err) => log("cloud device removal failed:", err.message));
      cloud.unmapDevice(params.id);
    }
    return localRemove(params);
  };
}

/** Keys load from the Keychain before the first request is served. */
export const ready = Promise.all([initProviders(), railway.load(), remoteDevices.load(), cloud.load()])
  .catch((err) => log("couldn’t load keys:", err instanceof Error ? err.message : err))
  .then(() => routines.start());

/** Runs one method once the brain is ready. */
export async function invoke(method: string, params: unknown) {
  await ready;
  const handler = methods[method];
  if (!handler) throw new Error(`Unknown method: ${method}`);
  return (await handler(params ?? {})) ?? null;
}
