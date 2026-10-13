import { randomUUID } from "node:crypto";
import { Collection } from "../store.ts";
import type { Bot } from "../bots/bots.ts";
import { COMPUTER_TOOLS, runTool } from "../agent/tools.ts";
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
}

export interface Workplace {
  hands: Hands;
  computerName: string;
}

type Emit = (event: string, data: unknown) => void;
type FindWorkplace = (bot: Bot) => Promise<Workplace | null>;

/** How many past messages go back to the model with each turn. */
const HISTORY_LIMIT = 40;
/** Upper bound on model round-trips per user message. */
const MAX_STEPS = 30;

export class Conversations {
  private messages = new Collection<Message>("messages.json");
  private running = new Map<string, AbortController>();

  constructor(private emit: Emit, private workplace: FindWorkplace) {}

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
    return this.start(bot, routine.task, { id: routine.id, name: routine.name }).done;
  }

  private start(bot: Bot, text: string, routine?: Message["routine"]) {
    if (this.running.has(bot.id)) throw new Error(`${bot.name} is still working`);
    const prompt = text.trim();
    if (!prompt) throw new Error("Empty message");

    const user = this.add({ botId: bot.id, role: "user", text: prompt, ...(routine ? { routine } : {}) });
    this.emit("message", user);

    const abort = new AbortController();
    this.running.set(bot.id, abort);
    this.emit("bot.status", { botId: bot.id, status: "thinking" });

    const done = this.run(bot, abort.signal)
      .catch((err): RunOutcome => ({ ok: false, error: err instanceof Error ? err.message : String(err) }))
      .finally(() => {
        this.running.delete(bot.id);
        this.emit("bot.status", { botId: bot.id, status: "idle" });
      });
    return { userId: user.id, done };
  }

  private async run(bot: Bot, signal: AbortSignal): Promise<RunOutcome> {
    let place: Workplace | null = null;
    try {
      place = await this.workplace(bot);
    } catch (err) {
      this.failure(bot, "Couldn’t reach the device", err);
    }
    const transcript: ChatMessage[] = [{ role: "system", content: this.system(bot, place) }, ...this.past(bot)];

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
          tools: place ? COMPUTER_TOOLS : undefined,
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
      if (!result.toolCalls.length || !place) return { ok: true };

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

      if (visual) {
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

  private system(bot: Bot, place: Workplace | null) {
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
      "Messages marked [Scheduled routine] run on a schedule while the user may be away: do the whole task without asking questions, then end with a short report of what you did and found.",
      "Reply in the same language the user writes in, and be direct.",
    ].filter(Boolean).join("\n\n");
  }

  private past(bot: Bot): ChatMessage[] {
    return this.history(bot.id)
      .filter((m) => (m.role === "user" || m.role === "assistant") && !m.error && m.text)
      .slice(-HISTORY_LIMIT)
      .map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.routine ? `[Scheduled routine “${m.routine.name}”] ${m.text}` : m.text,
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
     open_app: "open the app", shell: "run the command", screenshot: "see the screen", wait: "wait" } as Record<string, string>)[tool] ?? tool;

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
