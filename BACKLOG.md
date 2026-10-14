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

- **Run while the app is closed.** The scheduler lives in the brain, which the
  app starts, so routines only run with Local Bot open. Move the brain into a
  background service (LaunchAgent) so routines run 24/7.
- **Notifications** when a routine finishes or fails (needs a bundled app with
  a bundle id for `UNUserNotificationCenter`).
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
- **Long-term memory** per bot (today it's only the last 40 chat messages).
