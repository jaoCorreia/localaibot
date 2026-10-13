import { randomUUID } from "node:crypto";
import { Collection } from "../store.ts";
import type { Bot } from "../bots/bots.ts";
import { COMPUTER_TOOLS, runTool } from "../agent/tools.ts";
import type { Hands } from "../hands/types.ts";
import { provider } from "./providers.ts";
import type { ChatMessage, ContentPart } from "./types.ts";

export interface Message {
  id: string;
  botId: string;
  /** "activity" lines record what the bot did on its computer. */
  role: "user" | "assistant" | "activity";
  text: string;
  at: string;
  error?: string;
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
    if (this.running.has(bot.id)) throw new Error(`${bot.name} is still working`);
    const prompt = text.trim();
    if (!prompt) throw new Error("Empty message");

    const user = this.add({ botId: bot.id, role: "user", text: prompt });
    this.emit("message", user);

    const abort = new AbortController();
    this.running.set(bot.id, abort);
    this.emit("bot.status", { botId: bot.id, status: "thinking" });

    void this.run(bot, abort.signal).finally(() => {
      this.running.delete(bot.id);
      this.emit("bot.status", { botId: bot.id, status: "idle" });
    });
    return { userId: user.id };
  }

  private async run(bot: Bot, signal: AbortSignal) {
    let place: Workplace | null = null;
    try {
      place = await this.workplace(bot);
    } catch (err) {
      this.activity(bot, `Couldn’t reach the device: ${err instanceof Error ? err.message : err}`);
    }
    const transcript: ChatMessage[] = [{ role: "system", content: this.system(bot, place) }, ...this.past(bot)];

    if (place) {
      try {
        transcript.push(await this.look(place.hands, "Current screen of your device:"));
      } catch (err) {
        this.activity(bot, `Couldn’t see the screen: ${err instanceof Error ? err.message : err}`);
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
        if (!signal.aborted) reply.error = err instanceof Error ? err.message : String(err);
        this.finish(reply);
        return;
      }
      this.finish(reply);
      if (!result.toolCalls.length || !place) return;

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
        if (signal.aborted) return;
        let content: string;
        try {
          const outcome = await runTool(place.hands, call.function.name, call.function.arguments);
          this.activity(bot, outcome.activity);
          visual ||= outcome.visual;
          content = outcome.result;
        } catch (err) {
          if (deviceOff(err)) return this.activity(bot, "The device was turned off, so I stopped.");
          content = `Error: ${err instanceof Error ? err.message : err}`;
          this.activity(bot, `${call.function.name} failed: ${content.slice(7, 120)}`);
        }
        transcript.push({ role: "tool", tool_call_id: call.id, content });
      }

      if (visual) {
        await new Promise((r) => setTimeout(r, 600));
        try {
          dropOldScreens(transcript);
          transcript.push(await this.look(place.hands, "Screen after the actions:"));
        } catch (err) {
          if (deviceOff(err)) return this.activity(bot, "The device was turned off, so I stopped.");
          this.activity(bot, `Couldn’t see the screen: ${err instanceof Error ? err.message : err}`);
        }
      }
    }
    if (!signal.aborted) this.activity(bot, `Stopped after ${MAX_STEPS} steps.`);
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
      "Reply in the same language the user writes in, and be direct.",
    ].filter(Boolean).join("\n\n");
  }

  private past(bot: Bot): ChatMessage[] {
    return this.history(bot.id)
      .filter((m) => (m.role === "user" || m.role === "assistant") && !m.error && m.text)
      .slice(-HISTORY_LIMIT)
      .map((m) => ({ role: m.role as "user" | "assistant", content: m.text }));
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

  private activity(bot: Bot, text: string) {
    this.emit("message", this.add({ botId: bot.id, role: "activity", text }));
  }

  private add(m: Omit<Message, "id" | "at">): Message {
    return this.messages.upsert({ ...m, id: randomUUID(), at: new Date().toISOString() });
  }
}

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
