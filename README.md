# Local Bot

A local take on Grok Bot: AI bots that work on their own computers, with you
watching (and taking over) live. No cloud: you are the cloud.

- **Devices** are the machines bots work on: Linux desktops in Docker
  ([Cua](https://github.com/trycua/cua)'s `xfce-cua` image) or macOS VMs via
  [Lume](https://github.com/trycua/cua/tree/main/libs/lume). Simulators and
  remote machines are planned.
- **Bots** have a role, instructions, a model and a face. A bot owns a device
  or shares one as a guest.
- **Hands**: bots operate their device through
  [Cua Driver](https://github.com/trycua/cua/tree/main/libs/cua-driver)
  (screenshots, clicks, typing, shell), in an agent loop.
- **Models**: any OpenAI-compatible provider (OpenRouter, OpenAI, Anthropic,
  xAI, Gemini, Groq, Ollama, LM Studio, custom URL).

## Layout

```
brain/      TypeScript, cross-platform: bots, chat, agent loop, devices, providers
apps/mac/   Swift shell for macOS: window, device screen, native VM display
scripts/    dev helpers
```

The shell starts the brain and talks to it over JSON lines on stdio. Logic
lives in the brain so Windows/Linux shells can reuse it.

## Run (macOS, Apple silicon)

Requirements: Node 22+, Swift 6, Docker Desktop. Optional: Lume for macOS VMs.

```bash
scripts/dev-mac.sh
```

Add an AI provider in Settings (or put `OPENROUTER_API_KEY=…` in
`~/.local-bot/.env`), add a device with **+**, create a bot and give it a task.

Local state (bots, chats, keys, VNC password) lives in `~/.local-bot`, never in
this repo.
