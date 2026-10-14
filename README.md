<p align="center">
  <img src="assets/AppIcon.png" width="128" height="128" alt="Local Bot icon">
</p>

<h1 align="center">Local Bot</h1>

<p align="center">
  AI bots that work on their own computers, right on your Mac.<br>
  <a href="https://github.com/patrick-mns/localbot/releases/latest">Download</a>
</p>

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
device/     Image for remote devices: the Linux desktop plus an MCP agent
scripts/    dev helpers
```

The shell starts the brain and talks to it over JSON lines on stdio. Logic
lives in the brain so Windows/Linux shells can reuse it.

## Install

Download `LocalBot-<version>.dmg` from
[Releases](https://github.com/patrick-mns/localbot/releases), open it and drag
**Local Bot** to Applications.

Requirements: a Mac with Apple silicon and macOS 14+, and
[Docker Desktop](https://www.docker.com/products/docker-desktop/) running
(bots' Linux computers run in Docker).

### First launch: allowing an unsigned app

The app isn't signed with an Apple Developer ID yet, so macOS blocks it the
first time ("Apple could not verify…" or "is damaged"). Allow it once, either way:

- **System Settings → Privacy & Security**, scroll down and click
  **Open Anyway** next to "Local Bot", then confirm.
- Or remove the quarantine flag in Terminal (after moving the app to
  Applications):

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Local Bot.app"
  ```

After that it opens normally.

On first launch a setup assistant connects an AI provider (your key goes to the
macOS Keychain), creates a Linux device and your first bot.

## Build from source (macOS, Apple silicon)

Requirements: Node 22+, Swift 6 (Xcode 16), Docker Desktop.

```bash
scripts/dev-mac.sh          # run from source
(cd brain && npm run check) # typecheck + tests
scripts/build-app.sh        # dist/Local Bot.app and dist/LocalBot-<version>.dmg
```

macOS VM devices (Lume) are experimental and off by default; set
`LOCALBOT_EXPERIMENTAL_MACOS=1` to try them.

Local state (bots, chats, memory, routines) lives in `~/.local-bot`; API keys
live in the macOS Keychain. Logs: `~/Library/Logs/LocalBot/brain.log`.

## Remote and cloud devices

Devices can also live off your Mac. The image in `device/` is the same Linux
desktop plus a small agent on one HTTP port, guarded by `LOCALBOT_TOKEN`:
`POST /mcp` serves the hands over MCP (`describe`, `screenshot`, `computer`,
`shell`) and every other path serves the screen (noVNC). Anything that speaks
those MCP tools can be a device, so new machine providers plug in the same way.

- **Linux in the cloud (Railway):** paste a Railway account token once (it
  goes to the Keychain) and Local Bot creates a service per device in a
  "Local Bot" project, with its own domain, token and screen password.
  Removing the device deletes the service. Railway bills for the time it runs.
- **Connect a machine:** run the image anywhere (a VPS, another computer)
  and add it with its URL and token:

  ```bash
  docker run -d -p 8080:8080 --shm-size=1g \
    -e LOCALBOT_TOKEN=$(openssl rand -hex 24) -e VNC_PW=$(openssl rand -hex 6) \
    ghcr.io/jaocorreia/localbot-device:latest
  ```

  Put it behind HTTPS; the app refuses plain `http://` except for localhost.

The image is built and published by `.github/workflows/device-image.yml`.
Set `LOCALBOT_DEVICE_IMAGE` to make Railway devices run a different image.

## License

MIT, see [LICENSE](LICENSE).
