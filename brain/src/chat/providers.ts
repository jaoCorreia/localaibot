import { existsSync } from "node:fs";
import { join } from "node:path";
import { HOME, Settings } from "../store.ts";
import { OpenAICompatibleProvider } from "./openai-compatible.ts";
import type { ChatProvider } from "./types.ts";

// Keys can live in ~/.local-bot/.env (0600) instead of the shell environment.
const envFile = join(HOME, ".env");
if (existsSync(envFile)) process.loadEnvFile(envFile);

/**
 * Known services. All of them speak the OpenAI Chat Completions API, so one
 * client covers every preset; "custom" takes any compatible base URL.
 */
export interface Preset {
  id: string;
  label: string;
  baseURL: string;
  /** Environment variable that can hold the key instead of the config file. */
  envKey?: string;
  keyless?: boolean;
  local?: boolean;
  editableURL?: boolean;
  suggestedModel?: string;
  keyURL?: string;
  headers?: Record<string, string>;
}

export const PRESETS: Preset[] = [
  {
    id: "openrouter", label: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", envKey: "OPENROUTER_API_KEY",
    suggestedModel: "anthropic/claude-haiku-5.5", keyURL: "https://openrouter.ai/keys",
    headers: { "HTTP-Referer": "https://github.com/local-bot", "X-Title": "Local Bot" },
  },
  { id: "openai", label: "OpenAI", baseURL: "https://api.openai.com/v1", envKey: "OPENAI_API_KEY", keyURL: "https://platform.openai.com/api-keys" },
  { id: "anthropic", label: "Anthropic", baseURL: "https://api.anthropic.com/v1", envKey: "ANTHROPIC_API_KEY", suggestedModel: "claude-haiku-5-5", keyURL: "https://console.anthropic.com/settings/keys" },
  { id: "xai", label: "xAI (Grok)", baseURL: "https://api.x.ai/v1", envKey: "XAI_API_KEY", keyURL: "https://console.x.ai" },
  { id: "gemini", label: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", envKey: "GEMINI_API_KEY", keyURL: "https://aistudio.google.com/apikey" },
  { id: "groq", label: "Groq", baseURL: "https://api.groq.com/openai/v1", envKey: "GROQ_API_KEY", keyURL: "https://console.groq.com/keys" },
  { id: "ollama", label: "Ollama", baseURL: "http://localhost:11434/v1", keyless: true, local: true, editableURL: true },
  { id: "lmstudio", label: "LM Studio", baseURL: "http://localhost:1234/v1", keyless: true, local: true, editableURL: true },
  { id: "custom", label: "Custom", baseURL: "", editableURL: true },
];

/** A provider the user added: a preset plus their URL/key. */
export interface ProviderConfig {
  id: string;
  preset: string;
  label: string;
  baseURL: string;
  apiKey?: string;
}

interface Config {
  providers: ProviderConfig[];
  defaultProvider: string;
  defaultModel: string;
  /** Legacy single-key shape, migrated on load. */
  keys?: Record<string, string>;
}

export const settings = new Settings<Config>({
  providers: [],
  defaultProvider: "openrouter",
  defaultModel: "anthropic/claude-haiku-5.5",
});

migrate();

function migrate() {
  const v = settings.value;
  let providers = [...(v.providers ?? [])];
  for (const [id, apiKey] of Object.entries(v.keys ?? {})) {
    if (!providers.some((p) => p.id === id)) providers.push(fromPreset(id, { apiKey }));
  }
  // A key in the environment makes that service show up without any setup.
  for (const preset of PRESETS) {
    if (preset.envKey && process.env[preset.envKey] && !providers.some((p) => p.preset === preset.id)) {
      providers.push(fromPreset(preset.id, {}));
    }
  }
  if (providers.length !== (v.providers ?? []).length || v.keys) {
    settings.update({ providers, keys: undefined });
  }
}

function preset(id: string): Preset {
  const p = PRESETS.find((x) => x.id === id);
  if (!p) throw new Error(`Unknown provider: ${id}`);
  return p;
}

function fromPreset(presetId: string, over: Partial<ProviderConfig>): ProviderConfig {
  const p = preset(presetId);
  const taken = new Set(settings.value.providers?.map((x) => x.id));
  let id = over.id ?? p.id;
  for (let n = 2; taken.has(id); n++) id = `${p.id}-${n}`;
  return { id, preset: p.id, label: over.label?.trim() || p.label, baseURL: over.baseURL?.trim() || p.baseURL, apiKey: over.apiKey?.trim() || undefined };
}

function config(id: string): ProviderConfig {
  const c = settings.value.providers.find((p) => p.id === id);
  if (!c) throw new Error(`Provider not set up: ${id}`);
  return c;
}

const keyOf = (c: ProviderConfig) => c.apiKey || (preset(c.preset).envKey ? process.env[preset(c.preset).envKey!] : undefined);

const clients = new Map<string, { signature: string; client: ChatProvider }>();

export function provider(id: string): ChatProvider {
  const c = config(id);
  const p = preset(c.preset);
  // Rebuild the client when its settings change (keeps the model cache otherwise).
  const signature = `${c.baseURL}|${keyOf(c) ?? ""}`;
  const cached = clients.get(id);
  if (cached?.signature === signature) return cached.client;
  const client = new OpenAICompatibleProvider({
    id: c.id,
    label: c.label,
    baseURL: c.baseURL.replace(/\/+$/, ""),
    apiKey: () => keyOf(config(id)),
    headers: p.headers,
    keyless: p.keyless || (p.id === "custom" && !c.apiKey),
  });
  clients.set(id, { signature, client });
  return client;
}

/** Everything the UI needs, never the keys themselves. */
export function providerStatus() {
  return {
    defaultProvider: settings.value.defaultProvider,
    defaultModel: settings.value.defaultModel,
    presets: PRESETS.map(({ headers, ...p }) => p),
    providers: settings.value.providers.map((c) => {
      const p = preset(c.preset);
      const key = keyOf(c);
      return {
        id: c.id,
        preset: c.preset,
        label: c.label,
        baseURL: c.baseURL,
        local: !!p.local,
        keyless: !!p.keyless,
        configured: !!c.baseURL && (!!p.keyless || !!key || (p.id === "custom")),
        keySource: c.apiKey ? "config" : key ? "env" : null,
        keyHint: key ? `…${key.slice(-4)}` : null,
      };
    }),
  };
}

export function addProvider(input: { preset: string; label?: string; baseURL?: string; apiKey?: string }) {
  const c = fromPreset(input.preset, input);
  if (!c.baseURL) throw new Error("Enter the provider base URL");
  const providers = [...settings.value.providers, c];
  const first = settings.value.providers.length === 0;
  settings.update({
    providers,
    ...(first ? { defaultProvider: c.id, defaultModel: preset(c.preset).suggestedModel ?? settings.value.defaultModel } : {}),
  });
  return c.id;
}

export function updateProvider(id: string, patch: { label?: string; baseURL?: string; apiKey?: string }) {
  const providers = settings.value.providers.map((c) => {
    if (c.id !== id) return c;
    return {
      ...c,
      ...(patch.label?.trim() ? { label: patch.label.trim() } : {}),
      ...(patch.baseURL?.trim() ? { baseURL: patch.baseURL.trim() } : {}),
      // undefined keeps the key, "" removes it.
      ...(patch.apiKey !== undefined ? { apiKey: patch.apiKey.trim() || undefined } : {}),
    };
  });
  settings.update({ providers });
}

export function removeProvider(id: string) {
  const providers = settings.value.providers.filter((c) => c.id !== id);
  clients.delete(id);
  const fallback = providers[0]?.id ?? "";
  settings.update({
    providers,
    ...(settings.value.defaultProvider === id ? { defaultProvider: fallback } : {}),
  });
}

export function setDefault(providerId: string, model: string) {
  config(providerId);
  if (!model.trim()) throw new Error("Empty model");
  settings.update({ defaultProvider: providerId, defaultModel: model.trim() });
}

export async function testProvider(id: string) {
  try {
    const models = await provider(id).models(true);
    return { ok: true, models: models.length };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : String(err) };
  }
}
