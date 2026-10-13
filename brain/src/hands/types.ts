/**
 * "Hands" act inside a computer. The default implementation drives Cua Driver,
 * which runs on macOS, Windows and Linux with the same tool surface, so the
 * agent loop doesn't care which computer it is on.
 */
export interface Screenshot {
  /** PNG, base64-encoded. */
  png: string;
  width: number;
  height: number;
}

export interface Hands {
  /** Short description of the machine for the model's system prompt. */
  describe(): string;
  screenshot(): Promise<Screenshot>;
  /** A Cua Driver tool call (click, type_text, press_key, hotkey, scroll, launch_app…). */
  act(tool: string, args: Record<string, unknown>): Promise<unknown>;
  /** Runs a shell command inside the computer. */
  shell(command: string, timeoutMs?: number): Promise<{ code: number; output: string }>;
}
