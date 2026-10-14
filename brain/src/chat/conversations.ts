import { randomUUID } from "node:crypto";
import { Collection } from "../store.ts";
import type { Bot } from "../bots/bots.ts";
import { ASK_BOT_TOOL, COMPUTER_TOOLS, runTool } from "../agent/tools.ts";
import type { Hands } from "../hands/types.ts";
import type { RunOutcome } from "../routines/routines.ts";
import { provider } from "./providers.ts";
import type { ChatMessage, ContentPart } from "./types.ts";

export interface Message {
  id: string;
  botId: string;
  /** "activity" lines record what the bot did on its computer. */
  role: "user" | "assistant" | "activity";
  text: string;
  at: string;
  /** Human-readable problem (assistant replies) or a failed step (activity). */
  error?: string;
  /** Technical detail behind an error, shown only on request. */
  detail?: string;
  /** Set on the prompt a routine posted, so the chat can label it. */
  routine?: { id: string; name: string };
  /** Set on a prompt another bot sent through ask_bot. */
  from?: { botId: string; name: string };
}

export interface Workplace {
  hands: Hands;
  computerName: string;
}

type Emit = (event: string, data: unknown) => void;
type FindWorkplace = (bot: Bot) => Promise<Workplace | null>;
/** All bots, for delegation. */
type Team = () => Bot[];

interface TurnOptions {
  routine?: Message["routine"];
  from?: Message["from"];
  /** Bots already working on this request, outermost first (prevents loops). */
  chain?: string[];
}

/** How many past messages go back to the model with each turn. */
const HISTORY_LIMIT = 40;
/** Upper bound on model round-trips per user message. */
const MAX_STEPS = 30;
/** How many hops a request may travel: A → B → C, no further. */
const MAX_DELEGATION_HOPS = 2;
/** How long to wait for a busy teammate, and for a teammate's answer. */
const BUSY_WAIT_MS = 90_000;
const DELEGATION_TIMEOUT_MS = 10 * 60_000;

export class Conversations {
  private messages = new Collection<Message>("messages.json");
  private running = new Map<string, AbortController>();

  constructor(private emit: Emit, private workplace: FindWorkplace, private team: Team = () => []) {}

  history(botId: string) {
    return this.messages.where((m) => m.botId === botId);
  }

  isBusy(botId: string) {
    return this.running.has(botId);
  }

  clear(botId: string) {
    this.stop(botId);
    this.messages.remove((m) => m.botId === botId);
  }

  stop(botId: string) {
    this.running.get(botId)?.abort();
  }

  /** Records the user's message and runs the bot in the background; progress arrives as events. */
  async send(bot: Bot, text: string) {
    const { userId } = this.start(bot, text);
    return { userId };
  }

  /** Runs a routine's task as a turn in the bot's chat and resolves when it ends. */
  runRoutine(bot: Bot, routine: { id: string; name: string; task: string }): Promise<RunOutcome> {
    return this.start(bot, routine.task, { routine: { id: routine.id, name: routine.name } }).done;
  }

  private start(bot: Bot, text: string, opts: TurnOptions = {}) {
    const { routine, from } = opts;
    const chain = opts.chain ?? [bot.id];
    if (this.running.has(bot.id)) throw new Error(`${bot.name} is still working`);
    const prompt = text.trim();
    if (!prompt) throw new Error("Empty message");

    const user = this.add({ botId: bot.id, role: "user", text: prompt, ...(routine ? { routine } : {}), ...(from ? { from } : {}) });
    this.emit("message", user);

    const abort = new AbortController();
    this.running.set(bot.id, abort);
    this.emit("bot.status", { botId: bot.id, status: "thinking" });

    const done = this.run(bot, abort.signal, chain)
      .catch((err): RunOutcome => ({ ok: false, error: err instanceof Error ? err.message : String(err) }))
      .finally(() => {
        this.running.delete(bot.id);
        this.emit("bot.status", { botId: bot.id, status: "idle" });
      });
    return { userId: user.id, done };
  }

  private async run(bot: Bot, signal: AbortSignal, chain: string[]): Promise<RunOutcome> {
    const teammates = chain.length <= MAX_DELEGATION_HOPS ? this.teammates(chain) : [];
    const tools = [...(teammates.length ? [ASK_BOT_TOOL] : [])];
    let lastReply: string | undefined;
    let place: Workplace | null = null;
    try {
      place = await this.workplace(bot);
    } catch (err) {
      this.failure(bot, "Couldn’t reach the device", err);
    }
    const transcript: ChatMessage[] = [
      { role: "system", content: this.system(bot, place, teammates) },
      ...this.past(bot),
      // Restated after the history so earlier turns can't override the current state.
      {
        role: "system",
        content: place
          ? `Current state: you have the device "${place.computerName}" and can use it now.`
          : "Current state: you have NO device right now. Earlier messages may mention one you no longer have; don't claim to see or use a screen.",
      },
    ];

    if (place) {
      try {
        transcript.push(await this.look(place.hands, "Current screen of your device:"));
      } catch (err) {
        this.failure(bot, "Couldn’t see the screen", err);
      }
    }

    for (let step = 0; step < MAX_STEPS && !signal.aborted; step++) {
      const reply = this.draft(bot);
      let result;
      try {
        result = await provider(bot.provider).chat({
          model: bot.model,
          messages: transcript,
          tools: place ? [...COMPUTER_TOOLS, ...tools] : tools.length ? tools : undefined,
          signal,
          onDelta: (delta) => {
            reply.text += delta;
            this.emit("message.delta", { id: reply.id, botId: bot.id, delta });
          },
        });
      } catch (err) {
        if (!signal.aborted) {
          reply.error = friendlyProviderError(err);
          reply.detail = err instanceof Error ? err.message : String(err);
        }
        this.finish(reply);
        return signal.aborted ? { ok: false, error: "Stopped" } : { ok: false, error: reply.error };
      }
      this.finish(reply);
      if (reply.text.trim()) lastReply = reply.text.trim();
      if (!result.toolCalls.length) return { ok: true, reply: lastReply };

      transcript.push({
        role: "assistant",
        content: result.text,
        tool_calls: result.toolCalls.map((c) => ({
          id: c.id || randomUUID(),
          type: "function" as const,
          function: { name: c.name, arguments: c.arguments || "{}" },
        })),
      });

      let visual = false;
      for (const call of (transcript.at(-1) as Extract<ChatMessage, { role: "assistant" }>).tool_calls!) {
        if (signal.aborted) return { ok: false, error: "Stopped" };
        let content: string;
        if (call.function.name === ASK_BOT_TOOL.name) {
          content = await this.delegate(bot, chain, call.function.arguments, signal);
          transcript.push({ role: "tool", tool_call_id: call.id, content });
          continue;
        }
        if (!place) {
          transcript.push({ role: "tool", tool_call_id: call.id, content: "Error: you have no device to do that." });
          continue;
        }
        try {
          const outcome = await runTool(place.hands, call.function.name, call.function.arguments);
          this.activity(bot, outcome.activity);
          visual ||= outcome.visual;
          content = outcome.result;
        } catch (err) {
          if (deviceOff(err)) {
            this.failure(bot, "The device was turned off, so I stopped", err);
            return { ok: false, error: "The device is off." };
          }
          content = `Error: ${err instanceof Error ? err.message : err}`;
          this.failure(bot, `Couldn’t ${stepVerb(call.function.name)}`, err);
        }
        transcript.push({ role: "tool", tool_call_id: call.id, content });
      }

      if (visual && place) {
        await new Promise((r) => setTimeout(r, 600));
        try {
          dropOldScreens(transcript);
          transcript.push(await this.look(place.hands, "Screen after the actions:"));
        } catch (err) {
          if (deviceOff(err)) {
            this.failure(bot, "The device was turned off, so I stopped", err);
            return { ok: false, error: "The device is off." };
          }
          this.failure(bot, "Couldn’t see the screen", err);
        }
      }
    }
    if (signal.aborted) return { ok: false, error: "Stopped" };
    this.activity(bot, `Stopped after ${MAX_STEPS} steps`);
    return { ok: false, error: `Didn’t finish within ${MAX_STEPS} steps` };
  }

  /** Bots that can be asked from this request: everyone not already in the chain. */
  private teammates(chain: string[]) {
    return this.team().filter((b) => !chain.includes(b.id));
  }

  /**
   * ask_bot: runs the request as a turn in the teammate's own chat (on their
   * device, with their tools) and returns their final reply as the tool result.
   */
  private async delegate(from: Bot, chain: string[], rawArgs: string, signal: AbortSignal): Promise<string> {
    let args: { bot?: string; message?: string };
    try {
      args = JSON.parse(rawArgs || "{}");
    } catch {
      return "Error: invalid arguments for ask_bot.";
    }
    const message = String(args.message ?? "").trim();
    if (!message) return "Error: the message is empty.";

    const others = this.team().filter((b) => b.id !== from.id);
    const wanted = String(args.bot ?? "").trim().toLowerCase();
    const target =
      others.find((b) => b.name.toLowerCase() === wanted) ??
      others.find((b) => b.name.toLowerCase().startsWith(wanted) && wanted.length >= 2);
    if (!target) {
      return `Error: no teammate called "${args.bot}". Teammates: ${others.map((b) => b.name).join(", ") || "none"}.`;
    }
    if (chain.includes(target.id)) {
      return `Error: ${target.name} is already part of this request; asking them would create a loop.`;
    }
    if (chain.length > MAX_DELEGATION_HOPS) {
      return "Error: this request has been passed along too many times; finish it yourself.";
    }

    this.activity(from, `Asked ${target.name}: “${message.length > 90 ? `${message.slice(0, 90)}…` : message}”`);

    // Wait for a busy teammate a little, then give up.
    const waitUntil = Date.now() + BUSY_WAIT_MS;
    while (this.isBusy(target.id)) {
      if (signal.aborted) return "Error: stopped.";
      if (Date.now() > waitUntil) {
        this.failure(from, `${target.name} was busy`, new Error(`${target.name} was busy for over ${BUSY_WAIT_MS / 1000}s`));
        return `Error: ${target.name} is busy with another task right now.`;
      }
      await new Promise((r) => setTimeout(r, 2_000));
    }

    const turn = this.start(target, message, { from: { botId: from.id, name: from.name }, chain: [...chain, target.id] });
    // Stopping the asker stops the teammate too.
    const stopTarget = () => this.stop(target.id);
    signal.addEventListener("abort", stopTarget, { once: true });
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<RunOutcome>((resolve) => {
      timer = setTimeout(() => {
        this.stop(target.id);
        resolve({ ok: false, error: `No answer within ${DELEGATION_TIMEOUT_MS / 60_000} minutes` });
      }, DELEGATION_TIMEOUT_MS);
    });
    const outcome = await Promise.race([turn.done, timeout]);
    clearTimeout(timer);
    signal.removeEventListener("abort", stopTarget);

    if (!outcome.ok) {
      this.failure(from, `${target.name} couldn’t finish`, new Error(outcome.error ?? "unknown error"));
      return `Error: ${target.name} couldn’t finish: ${outcome.error ?? "unknown error"}.`;
    }
    const reply = outcome.reply ?? "(no text reply)";
    this.activity(from, `${target.name} replied: “${reply.length > 120 ? `${reply.slice(0, 120)}…` : reply}”`);
    return `${target.name} replied:\n${reply}`;
  }

  private async look(hands: Hands, caption: string): Promise<ChatMessage> {
    const shot = await hands.screenshot();
    return {
      role: "user",
      content: [
        { type: "text", text: `${caption} (${shot.width}x${shot.height})` },
        { type: "image_url", image_url: { url: `data:image/png;base64,${shot.png}` } },
      ],
    };
  }

  private system(bot: Bot, place: Workplace | null, teammates: Bot[]) {
    return [
      `You are ${bot.name}, a bot in Local Bot.`,
      `Now: ${new Date().toLocaleString("en-US", { dateStyle: "full", timeStyle: "short" })} (${Intl.DateTimeFormat().resolvedOptions().timeZone}).`,
      bot.role && `Your role: ${bot.role}.`,
      bot.instructions,
      place
        ? [
            `You work on the device "${place.computerName}" and can operate it with the tools.`,
            place.hands.describe(),
            "How to work:",
            "- Look at the screenshot before acting; coordinates are pixels of the latest screenshot.",
            "- Prefer keyboard shortcuts (ctrl+l for the address bar, Return to confirm).",
            "- To open websites, use open_app with firefox-esr and the URL.",
            "- After every action you get a fresh screenshot; check the result before moving on.",
            "- Never make purchases, send messages or delete things irreversibly without asking the user first.",
            "- When you are done, reply to the user with a short summary of what you did.",
          ].join("\n")
        : "You don't have a running device yet. If the task needs one, tell the user to start or assign a device.",
      teammates.length
        ? [
            "Your teammates (other bots). Use ask_bot to hand them work that fits their role or needs their device:",
            ...teammates.map((t) => `- ${t.name}${t.role ? `: ${t.role}` : ""}`),
          ].join("\n")
        : "",
      "Messages marked [Scheduled routine] run on a schedule while the user may be away: do the whole task without asking questions, then end with a short report of what you did and found.",
      "Messages marked [From bot …] come from a teammate, not the user: do what they ask and end with a clear, self-contained answer; that answer is sent back to them. Ask them questions only if you truly can't proceed.",
      "Reply in the same language the user writes in, and be direct.",
    ].filter(Boolean).join("\n\n");
  }

  private past(bot: Bot): ChatMessage[] {
    return this.history(bot.id)
      .filter((m) => (m.role === "user" || m.role === "assistant") && !m.error && m.text)
      .slice(-HISTORY_LIMIT)
      .map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.routine
          ? `[Scheduled routine “${m.routine.name}”] ${m.text}`
          : m.from
            ? `[From bot “${m.from.name}”] ${m.text}`
            : m.text,
      }));
  }

  private draft(bot: Bot): Message {
    const msg: Message = { id: randomUUID(), botId: bot.id, role: "assistant", text: "", at: new Date().toISOString() };
    this.emit("message", msg);
    return msg;
  }

  /** Persists a streamed reply; empty ones (pure tool calls) are dropped from the chat. */
  private finish(msg: Message) {
    if (msg.text.trim() || msg.error) this.messages.upsert(msg);
    this.emit("message.done", { ...msg, empty: !msg.text.trim() && !msg.error });
  }

  /** A failed step: a short human title, plus why, plus the raw error for "Details". */
  private failure(bot: Bot, title: string, err: unknown) {
    const raw = err instanceof Error ? err.message : String(err);
    this.emit("message", this.add({ botId: bot.id, role: "activity", text: title, error: friendlyDeviceError(raw), detail: raw }));
  }

  private activity(bot: Bot, text: string) {
    this.emit("message", this.add({ botId: bot.id, role: "activity", text }));
  }

  private add(m: Omit<Message, "id" | "at">): Message {
    return this.messages.upsert({ ...m, id: randomUUID(), at: new Date().toISOString() });
  }
}

/** Plain-language reason for a device-side failure. */
function friendlyDeviceError(raw: string): string {
  if (/is not running|No such container/i.test(raw)) return "The device is off.";
  if (/session has ended|session_ended/i.test(raw)) return "Lost the session with the device’s controls.";
  if (/daemon is not running|cua-driver\.sock|ECONNREFUSED/i.test(raw)) return "The device’s controls aren’t running.";
  if (/timed out|ETIMEDOUT|killed/i.test(raw)) return "The device took too long to respond.";
  if (/permission|not permitted|refused/i.test(raw)) return "The device didn’t allow that action.";
  return "Something went wrong on the device.";
}

/** Plain-language reason for a model/provider failure. */
function friendlyProviderError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  if (/no api key|has no API key/i.test(raw)) return "This bot’s AI provider has no API key. Add one in Settings.";
  if (/\b401\b|unauthori[sz]ed|invalid api key/i.test(raw)) return "The AI provider rejected the API key. Check it in Settings.";
  if (/\b402\b|credits|insufficient/i.test(raw)) return "The AI provider account is out of credits.";
  if (/\b429\b|rate limit/i.test(raw)) return "The AI provider is rate limiting. Try again in a moment.";
  if (/\b404\b|model.*not found|no endpoints/i.test(raw)) return "This model isn’t available. Pick another in the bot settings.";
  if (/not set up|Unknown provider/i.test(raw)) return "This bot’s AI provider was removed. Pick another in the bot settings.";
  if (/fetch failed|ENOTFOUND|ECONNREFUSED|network/i.test(raw)) return "Couldn’t reach the AI provider. Check your connection.";
  if (/\b5\d\d\b/.test(raw)) return "The AI provider had a problem. Try again.";
  return "The AI provider returned an error.";
}

const stepVerb = (tool: string) =>
  ({ click: "click", type_text: "type", press_key: "press the key", hotkey: "use the shortcut", scroll: "scroll",
     open_app: "open the app", shell: "run the command", screenshot: "see the screen", wait: "wait",
     ask_bot: "ask the teammate" } as Record<string, string>)[tool] ?? tool;

/** Docker reports a stopped container this way; there is no point retrying. */
function deviceOff(err: unknown) {
  return /is not running|No such container/i.test(err instanceof Error ? err.message : String(err));
}

/** Keeps only the newest screenshot in context; older ones become a short note. */
function dropOldScreens(transcript: ChatMessage[]) {
  for (const m of transcript) {
    if (m.role === "user" && Array.isArray(m.content) && m.content.some((p) => p.type === "image_url")) {
      m.content = m.content.map((p): ContentPart => (p.type === "image_url" ? { type: "text", text: "(older screenshot omitted)" } : p));
    }
  }
}
