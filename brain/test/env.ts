// Imported first by every test: isolated data dir and file-based secrets,
// so tests never touch ~/.local-bot or the real Keychain.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.LOCALBOT_HOME = mkdtempSync(join(tmpdir(), "localbot-test-"));
process.env.LOCALBOT_SECRETS = "file";
for (const k of ["OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY"]) {
  delete process.env[k];
}
