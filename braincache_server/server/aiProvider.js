// AI provider resolution — the ONE place that knows where requests go.
//
// Default (and primary) path: NVIDIA Nemotron 3 models served by Nebius Token
// Factory through its OpenAI-compatible Chat Completions API. A legacy OpenAI
// path is kept only as a fallback when NEBIUS_API_KEY is absent but
// OPENAI_API_KEY is set.
//
// Roles:
//   fast      — Nemotron 3 Nano   — chat follow-ups (cheap, quick)
//   agent     — Nemotron 3 Super  — tool-calling analysis loop + skill authoring
//   reasoning — Nemotron 3 Ultra  — cross-app goal assignment pass
//   omni      — Nemotron 3 Nano Omni — audio transcription + screenshot vision

export const NEBIUS_BASE_URL = "https://api.tokenfactory.nebius.com/v1";
export const OPENAI_BASE_URL = "https://api.openai.com/v1";

export const NEMOTRON_DEFAULTS = Object.freeze({
  fast: "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B",
  agent: "nvidia/nemotron-3-super-120b-a12b",
  reasoning: "nvidia/Nemotron-3-Ultra-550b-a55b",
  omni: "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning"
});

export const OPENAI_DEFAULT_MODEL = "gpt-5.5";

// Extra body fields that OpenAI-compatible servers usually accept but may
// reject. When a 400 names an unknown field, the request is retried once
// without them.
const OPTIONAL_BODY_FIELDS = ["top_k", "chat_template_kwargs"];

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export function getProviderConfig(env = process.env) {
  const nebiusKey = trim(env.NEBIUS_API_KEY);
  const openaiKey = trim(env.OPENAI_API_KEY);
  const genericKey = trim(env.AI_API_KEY);

  // Legacy OpenAI fallback only when no Nebius/generic key is present.
  const provider = !nebiusKey && !genericKey && openaiKey ? "openai" : "nebius";
  const apiKey = genericKey || (provider === "openai" ? openaiKey : nebiusKey);

  const defaultBase = provider === "openai" ? OPENAI_BASE_URL : trim(env.NEBIUS_BASE_URL) || NEBIUS_BASE_URL;
  const baseUrl = (trim(env.AI_BASE_URL) || defaultBase).replace(/\/+$/, "");

  const models = provider === "openai"
    ? sameModelForAllRoles(trim(env.OPENAI_MODEL) || OPENAI_DEFAULT_MODEL)
    : {
        fast: trim(env.NEMOTRON_FAST_MODEL) || NEMOTRON_DEFAULTS.fast,
        agent: trim(env.NEMOTRON_AGENT_MODEL) || NEMOTRON_DEFAULTS.agent,
        reasoning: trim(env.NEMOTRON_REASONING_MODEL) || NEMOTRON_DEFAULTS.reasoning,
        omni: trim(env.NEMOTRON_OMNI_MODEL) || NEMOTRON_DEFAULTS.omni
      };

  return {
    provider,
    providerLabel: provider === "openai" ? "OpenAI (legacy fallback)" : "Nebius Token Factory",
    baseUrl,
    apiKey,
    enabled: Boolean(apiKey),
    models,
    limits: {
      maxToolRounds: envNumber(env, ["AI_MAX_TOOL_ROUNDS", "OPENAI_MAX_TOOL_ROUNDS"], 8),
      maxToolCalls: envNumber(env, ["AI_MAX_TOOL_CALLS", "OPENAI_MAX_TOOL_CALLS"], 14),
      timeoutMs: envNumber(env, ["AI_TIMEOUT_MS", "OPENAI_TIMEOUT_MS"], 240000),
      maxOutputTokens: envNumber(env, ["AI_MAX_OUTPUT_TOKENS", "OPENAI_MAX_OUTPUT_TOKENS"], 24000),
      transcribeTimeoutMs: envNumber(env, ["AI_TRANSCRIBE_TIMEOUT_MS"], 600000),
      transcribeChunkSeconds: envNumber(env, ["AI_TRANSCRIBE_CHUNK_SECONDS"], 600)
    }
  };
}

// Read the first defined numeric env var from `names`, else `fallback`.
export function envNumber(env, names, fallback) {
  for (const name of names) {
    const value = Number(env[name]);
    if (env[name] !== undefined && env[name] !== "" && Number.isFinite(value)) return value;
  }
  return fallback;
}

function sameModelForAllRoles(model) {
  return { fast: model, agent: model, reasoning: model, omni: model };
}

function trim(value) {
  return String(value ?? "").trim();
}

// ---------------------------------------------------------------------------
// Transport — Chat Completions (OpenAI-compatible)
// ---------------------------------------------------------------------------

export async function chatCompletion(body, { timeoutMs, config = getProviderConfig() } = {}) {
  if (!config.apiKey) {
    throw new Error("AI requests need a Nebius Token Factory key. Set NEBIUS_API_KEY on the server.");
  }
  const timeout = timeoutMs ?? config.limits.timeoutMs;
  const post = (payload) => postJson(`${config.baseUrl}/chat/completions`, payload, { apiKey: config.apiKey, timeoutMs: timeout });

  // OpenAI-compatible servers disagree about the edges of the schema (some
  // models renamed max_tokens, some reject top_k or a custom temperature).
  // A 400 that names one tunable field is repaired and retried, never guessed
  // about more than MAX_BODY_REPAIRS times.
  let payload = body;
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await post(payload);
    } catch (error) {
      const repaired = attempt < MAX_BODY_REPAIRS ? repairRejectedBody(payload, error) : null;
      if (!repaired) throw error;
      console.warn(`[ai] ${config.baseUrl} rejected a field (${error.message}); retrying with ${repaired.reason}.`);
      payload = repaired.body;
    }
  }
}

const MAX_BODY_REPAIRS = 3;
// Fields the request cannot be repaired by dropping.
const ESSENTIAL_BODY_FIELDS = new Set(["model", "messages", "tools", "tool_choice"]);
// Same knob, different name on some servers.
const BODY_FIELD_RENAMES = Object.freeze({ max_tokens: "max_completion_tokens" });

// Given a 400 that names a tunable field, return the body to retry with.
// Returns null when the failure isn't a field the caller can give up on.
export function repairRejectedBody(body, error) {
  if (error?.status !== 400) return null;
  const message = String(error?.message || "");

  for (const [, field] of message.matchAll(/[`'"]([A-Za-z_][A-Za-z0-9_]*)[`'"]/g)) {
    if (!Object.hasOwn(body, field) || ESSENTIAL_BODY_FIELDS.has(field)) continue;
    const renamed = Object.hasOwn(BODY_FIELD_RENAMES, field) ? BODY_FIELD_RENAMES[field] : null;
    const { [field]: value, ...rest } = body;
    if (renamed && message.includes(renamed)) {
      return { body: { ...rest, [renamed]: value }, reason: `${field} renamed to ${renamed}` };
    }
    return { body: rest, reason: `${field} dropped` };
  }

  if (mentionsUnknownField(message) && OPTIONAL_BODY_FIELDS.some((field) => field in body)) {
    const stripped = { ...body };
    for (const field of OPTIONAL_BODY_FIELDS) delete stripped[field];
    return { body: stripped, reason: `${OPTIONAL_BODY_FIELDS.join("/")} dropped` };
  }
  return null;
}

// Same as chatCompletion, but the model is the omni role and a "model not
// found" reply triggers a one-time lookup of the served omni model id.
export async function omniChatCompletion(body, options = {}) {
  const config = options.config || getProviderConfig();
  const model = await resolveOmniModel({ config });
  try {
    return await chatCompletion({ ...body, model }, { ...options, config });
  } catch (error) {
    if (!looksLikeMissingModel(error) || config.provider !== "nebius") throw error;
    const discovered = await resolveOmniModel({ config, force: true });
    if (!discovered || discovered === model) throw error;
    console.warn(`[ai] omni model "${model}" not found; retrying with "${discovered}" from GET /models.`);
    return chatCompletion({ ...body, model: discovered }, { ...options, config });
  }
}

let omniModelCache = null;

// The omni model id is the least certain of the defaults. When the configured
// id is rejected we ask the provider which models it serves, pick the first
// one matching /omni/i, and cache it for the process lifetime.
export async function resolveOmniModel({ config = getProviderConfig(), force = false } = {}) {
  if (omniModelCache && !force) return omniModelCache;
  if (!force) {
    omniModelCache = config.models.omni;
    return omniModelCache;
  }
  const models = await listModels({ config });
  const match = models.find((id) => /omni/i.test(id));
  if (match) {
    omniModelCache = match;
    console.log(`[ai] resolved omni model via GET /models: ${match}`);
  }
  return omniModelCache || config.models.omni;
}

export function resetProviderCache() {
  omniModelCache = null;
}

export async function listModels({ config = getProviderConfig() } = {}) {
  const payload = await getJson(`${config.baseUrl}/models`, { apiKey: config.apiKey, timeoutMs: 30000 });
  const data = Array.isArray(payload?.data) ? payload.data : Array.isArray(payload) ? payload : [];
  return data.map((item) => (typeof item === "string" ? item : item?.id)).filter(Boolean);
}

// ---------------------------------------------------------------------------
// Response helpers (pure)
// ---------------------------------------------------------------------------

// Text of the first choice. Content may be a string or an array of parts.
export function messageText(response) {
  const message = response?.choices?.[0]?.message;
  if (!message) return "";
  const content = message.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === "string" ? part : part?.text || "")).join("");
  }
  return "";
}

export function messageToolCalls(response) {
  const calls = response?.choices?.[0]?.message?.tool_calls;
  return Array.isArray(calls) ? calls : [];
}

// Nemotron reasoning models may wrap their thinking in <think>…</think>.
// Strip every complete block, and an unterminated trailing one.
export function stripThinkTags(text) {
  return String(text ?? "")
    .replace(/<think>[\s\S]*?<\/think>/gi, "")
    .replace(/<think>[\s\S]*$/i, "")
    .trim();
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

async function postJson(url, body, { apiKey, timeoutMs }) {
  return request(url, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(body)
  }, timeoutMs);
}

async function getJson(url, { apiKey, timeoutMs }) {
  return request(url, { method: "GET", headers: { authorization: `Bearer ${apiKey}` } }, timeoutMs);
}

async function request(url, init, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await globalThis.fetch(url, { ...init, signal: controller.signal });
  } catch (error) {
    if (error.name === "AbortError") {
      throw new Error(`AI request timed out after ${Math.round(timeoutMs / 1000)}s.`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = payload?.error?.message || payload?.message || payload?.detail || `AI request failed (${response.status}).`;
    const error = new Error(typeof message === "string" ? message : JSON.stringify(message));
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function mentionsUnknownField(message) {
  return /unknown|unrecognized|unexpected|extra|not (?:a )?(?:valid|permitted|allowed|supported)|additional propert|invalid (?:parameter|field|argument)/i.test(String(message || ""));
}

function looksLikeMissingModel(error) {
  if (error?.status === 404) return true;
  return /model.*(?:not (?:found|exist|available)|does not exist|unknown)|no such model|not found/i.test(String(error?.message || ""));
}
