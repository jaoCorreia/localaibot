# Backlog

Ideas and known gaps, roughly grouped. Not ordered by priority.

## Models

- **Flag device-capable models in the model picker.** Using a device needs a
  model with image input (screenshots) and tool calling. OpenRouter's model
  list reports both (`architecture.input_modalities`, `supported_parameters`);
  show a "Can use devices" badge and warn when picking one that can't.
- **Text-only fallback for models without vision.** Cua Driver can describe the
  screen as an accessibility tree (buttons, fields, text). Send that instead of
  a screenshot to models without image input. Good for native apps, weaker on
  complex web pages; still needs tool calling.

## Routines

Done: routines run with the app closed (Settings → Background installs a
LaunchAgent; one brain owns the data at a time over ~/.local-bot/brain.sock),
notifications when a routine finishes or fails, and a menu bar icon.

- **Open at login without the LaunchAgent trick:** `SMAppService` once the app
  is signed with a Developer ID.
- **Teach a task:** record the user doing a workflow once (Cua Driver
  trajectory recording) and save it as a routine.

## Devices

- **Own Linux image** (`FROM trycua/xfce-cua`) with the current Cua Driver,
  Chromium and defaults baked in, instead of upgrading the driver at runtime.
- **macOS VM as a bot device:** install Cua Driver inside the Lume VM (and its
  permissions) so bots can use it; booting it in-app is still untested.
- **More device kinds:** iOS Simulator, Android Emulator, another computer on
  the network (remote broker / fleet).
- **Browser tools over CDP** for web tasks (more reliable than clicking pixels).

## Bots working together

Done: bots delegate to each other with `ask_bot` (runs in the teammate's chat,
answer returns to the asker; loop, depth, busy and timeout guards).

- **Group threads:** one conversation with several bots that coordinate on a
  task while the user watches (needs turn-taking: who speaks when).
- **@mentions in chat:** the user (or a bot in its reply) writes "@Ninja …" and
  that bot answers right there in the same chat, with its face, device and
  memory; mentioning bots hand the floor on (loop/hop limits). Includes `@`
  autocomplete in the composer and highlighted mentions.
- **Per-bot delegation settings:** which teammates a bot may ask, and whether
  it can be asked at all.

- **Turn-taking on shared devices:** one screen and keyboard per device, so
  bots sharing it need a lock/queue for GUI actions (watching can be shared).
- **Bots asking for access** to another bot's device, approved by the user or
  the owning bot, optionally time-limited.
- **Approvals for risky actions** (send, buy, delete) enforced in code, not
  only in the prompt.

## App

- **Rename `computers.*` to `devices.*`** in the brain protocol (the UI already
  says Devices).
- **Shells for Windows and Linux** reusing the brain.

## Memory

Done: local long-term memory (SQLite + FTS5 in ~/.local-bot/memory.db) with
core / facts (superseded, history kept) / how-tos / episodes, per bot or team;
remember / recall / forget tools; relevant memories injected each turn;
background consolidation after tasks; old chat folded into a running summary;
Memory tab to search, edit, pin, forget and delete.

- **Semantic search:** add embeddings (local via Ollama, or the provider's)
  next to BM25 for recall by meaning, not just words.
- **Consolidation passes over time:** periodically merge duplicates and resolve
  contradictions across all of a bot's memories ("sleep-time" pass).
- **Memory evals:** a small LongMemEval/LoCoMo-style check on our own chats.
- **Refresh other bots' Memory tabs** when a team memory changes.

## MCP servers

Give bots tools from MCP servers, set up in Settings. Grok's connectors take
only remote servers (URL + sign-in, no localhost); running on the Mac, we can
also run local stdio servers, where the most useful ones live.

- **Phase 1 — servers and tools:** `~/.local-bot/mcp.json` with HTTP servers
  (reuse `hands/mcp.ts`'s client) and stdio servers the brain starts on demand
  and restarts if they die; tokens and secret env vars in the Keychain.
  Methods `mcp.list/add/update/remove/test/tools`. Tools join the agent loop
  prefixed by server (`github__create_issue`), enabled per bot in the bot
  editor (off by default). Settings → "MCP Servers": status dots, Add server
  (Remote: URL + token; Local: command, args, env), page with discovered
  tools, Test, Remove, recent errors.
- **Phase 2 — safety and setup:** confirm write/destructive tools in the chat
  (Allow / Deny, "always allow" per tool; routines only use allowed ones);
  presets (Filesystem, GitHub, Fetch, Brave Search, Notion, Slack); OAuth for
  remote servers.
- **Phase 3 — cloud:** remote servers move with a bot to the cloud brain;
  local ones stay on the Mac and the app says so.
