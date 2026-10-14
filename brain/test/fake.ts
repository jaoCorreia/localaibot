import type { ChatProvider, ChatRequest, ChatResult, ToolCall } from "../src/chat/types.ts";

/** One scripted model turn: plain text and/or tool calls, or a function deciding it from the request. */
export type Turn = { text?: string; tools?: { name: string; args: Record<string, unknown> }[] };
export type Step = Turn | ((req: ChatRequest) => Turn);

/** A model that replays a script; records every request it received. */
export class FakeProvider implements ChatProvider {
  readonly id = "fake";
  readonly label = "Fake";
  requests: ChatRequest[] = [];
  constructor(private script: Step[]) {}

  configured() {
    return true;
  }

  async models() {
    return [{ id: "fake-1", name: "Fake 1" }];
  }

  async chat(req: ChatRequest): Promise<ChatResult> {
    this.requests.push(req);
    const next = this.script.shift() ?? { text: "(script ended)" };
    const step: Turn = typeof next === "function" ? next(req) : next;
    if (step.text) req.onDelta(step.text);
    const toolCalls: ToolCall[] = (step.tools ?? []).map((t, i) => ({ id: `call-${this.requests.length}-${i}`, name: t.name, arguments: JSON.stringify(t.args) }));
    return { text: step.text ?? "", toolCalls };
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
