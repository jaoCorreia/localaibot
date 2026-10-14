import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const HOME = process.env.LOCALBOT_HOME!;
// Legacy state from before the Keychain: a key in config.json and one in .env.
writeFileSync(join(HOME, "config.json"), JSON.stringify({
  providers: [{ id: "gemini", preset: "gemini", label: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", apiKey: "gem-key-1234" }],
  defaultProvider: "gemini", defaultModel: "x",
}));
writeFileSync(join(HOME, ".env"), "OPENROUTER_API_KEY=sk-or-test-9876\n");

const { addProvider, initProviders, providerStatus, removeProvider, resetProviders, updateProvider } = await import("../src/chat/providers.ts");

test("legacy keys move out of config.json and .env", async () => {
  await initProviders();
  const status = providerStatus();
  const byId = Object.fromEntries(status.providers.map((p) => [p.id, p]));
  assert.equal(byId.gemini.keySource, "keychain");
  assert.equal(byId.gemini.keyHint, "…1234");
  assert.equal(byId.openrouter.keySource, "keychain");
  assert.ok(!readFileSync(join(HOME, "config.json"), "utf8").includes("gem-key-1234"));
  assert.match(readFileSync(join(HOME, ".env"), "utf8"), /^# OPENROUTER_API_KEY=.*moved to the macOS Keychain/m);
  assert.ok(existsSync(join(HOME, "secrets.json")));
});

test("add / replace / remove keys, never exposing them", async () => {
  const id = await addProvider({ preset: "groq", apiKey: "groq-secret-0001" });
  assert.equal(providerStatus().providers.find((p) => p.id === id)!.keyHint, "…0001");
  assert.ok(!JSON.stringify(providerStatus()).includes("groq-secret-0001"));
  await updateProvider(id, { apiKey: "groq-secret-0002" });
  assert.equal(providerStatus().providers.find((p) => p.id === id)!.keyHint, "…0002");
  await updateProvider(id, { apiKey: "" });
  assert.equal(providerStatus().providers.find((p) => p.id === id)!.configured, false);
  await removeProvider(id);
  assert.ok(!providerStatus().providers.some((p) => p.id === id));
});

test("local providers need no key", async () => {
  const id = await addProvider({ preset: "ollama" });
  assert.equal(providerStatus().providers.find((p) => p.id === id)!.configured, true);
});

test("reset forgets every provider and its key", async () => {
  await addProvider({ preset: "openai", apiKey: "openai-secret-4242" });
  await resetProviders();
  assert.equal(providerStatus().providers.length, 0);
  assert.ok(!readFileSync(join(HOME, "secrets.json"), "utf8").includes("openai-secret-4242"));
});
