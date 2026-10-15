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
brain/Dockerfile  The brain as a cloud service, for bots that run 24/7
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

Updates install from inside the app (Local Bot → Check for Updates…, or the
banner in the sidebar). They come from this repo's releases through
[Sparkle](https://sparkle-project.org), and the app only installs an update
signed with the project's key, which is kept off GitHub.

On first launch a setup assistant connects an AI provider (your key goes to the
macOS Keychain), creates a Linux device and your first bot.

## Build from source (macOS, Apple silicon)

Requirements: Node 22+, Swift 6 (Xcode 16), Docker Desktop.

```bash
scripts/dev-mac.sh          # run from source
(cd brain && npm run check) # typecheck + tests
scripts/build-app.sh        # dist/Local Bot.app and dist/LocalBot-<version>.dmg
```

### Releasing

1. Bump `VERSION`, commit, then push a tag: `git tag -a v0.5.0 -m v0.5.0 && git push origin v0.5.0`.
   CI builds the DMG into a **draft** release.
2. On the maintainer's Mac (the Sparkle key is in its Keychain):
   `scripts/publish-release.sh v0.5.0`. It checks the DMG, signs it, uploads
   `appcast.xml` and publishes the release.

The signing key was made with Sparkle's `generate_keys --account localbot`;
its public half is `assets/sparkle-public-key.txt`. Back up the private key
(`generate_keys --account localbot -x key.txt`) somewhere safe: without it,
installed apps can't be updated anymore.

macOS VM devices (Lume) are experimental and off by default; set
`LOCALBOT_EXPERIMENTAL_MACOS=1` to try them.

**Background:** Settings → Background keeps routines running while Local Bot
is closed. It installs a LaunchAgent (`~/Library/LaunchAgents/io.github.patrick-mns.localbot.*`)
that runs the brain as a service; the app then lives in the menu bar, ⌘Q only
closes the window, and routines notify you when they finish. Turning it off
removes the agents.

Local state (bots, chats, memory, routines) lives in `~/.local-bot`; API keys
live in the macOS Keychain. Logs: `~/Library/Logs/LocalBot/brain.log`.

## Remote and cloud devices

Devices can also live off your Mac. The image in `device/` is the same Linux
desktop plus a small agent on one HTTP port, guarded by `LOCALBOT_TOKEN`:
`POST /mcp` serves the hands over MCP (`describe`, `screenshot`, `computer`,
`shell`) and every other path serves the screen (noVNC). Anything that speaks
those MCP tools can be a device, so new machine providers plug in the same way.

- **Linux in the cloud (Railway):** connect a Railway account token in Settings → Device Providers (it
  goes to the Keychain) and Local Bot creates a service per device in a
  "Local Bot" project, with its own domain, token and screen password.
  Removing the device deletes the service. Railway bills for the time it runs.
- **Connect a machine:** paste a device's share code. Get one from
  "⋯ → Share device…" on a remote or cloud device in another Local Bot, or
  from the logs of your own server (a VPS, another computer) running the
  image behind HTTPS:

  ```bash
  docker run -d -p 8080:8080 --shm-size=1g \
    -e LOCALBOT_PUBLIC_URL=https://my-device.example.com \
    -e LOCALBOT_TOKEN=$(openssl rand -hex 24) -e VNC_PW=$(openssl rand -hex 6) \
    ghcr.io/patrick-mns/localbot-device:latest
  docker logs <container>   # prints the share code
  ```

  The code carries the URL, token and screen password, so it grants control
  of the machine: share it only with people you trust.

### Bots that keep working with the app closed

The brain can also run in the cloud (`brain/Dockerfile`, entry `src/server.ts`:
the same methods over HTTP + server-sent events, guarded by `BRAIN_TOKEN`).
In Settings → Device Providers → Railway, **Cloud brain → Set up** creates it
as a Railway service with a volume for its data. Then a bot's "⋯ → Move to
the cloud" moves its chat, routines and memory there: it keeps chatting,
running routines and learning while the Mac is off. Its devices must be
cloud or remote ones. While the app is open, the local brain forwards that
bot's methods to the cloud and relays its events, so it looks like any other
bot. "Move to this Mac" brings it back.

Images are built and published by `.github/workflows/device-image.yml` and
`brain-image.yml` (`LOCALBOT_BRAIN_IMAGE` overrides the brain's).
Set `LOCALBOT_DEVICE_IMAGE` to make Railway devices run a different image.

## License

MIT, see [LICENSE](LICENSE).
