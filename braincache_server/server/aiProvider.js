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

// Chat completion for one model role, with model-id self-repair: if the
// provider says the configured id does not exist, ask GET /models what it
// actually serves for that role and retry once.
export async function roleChatCompletion(role, body, options = {}) {
  const config = options.config || getProviderConfig();
  const model = await resolveModel(role, { config });
  try {
    return await chatCompletion({ ...body, model }, { ...options, config });
  } catch (error) {
    if (!looksLikeMissingModel(error) || config.provider === "openai") throw error;
    const discovered = await resolveModel(role, { config, force: true });
    if (!discovered || discovered === model) throw error;
    console.warn(`[ai] model "${model}" not found; retrying with "${discovered}" from GET /models.`);
    return chatCompletion({ ...body, model: discovered }, { ...options, config });
  }
}

// The omni role, which is how audio and screenshots reach the provider.
export function omniChatCompletion(body, options = {}) {
  return roleChatCompletion("omni", body, options);
}

// How to recognise a served model for each role when the configured id is
// wrong. Nemotron 3 Nano Omni also matches /nano/, so `fast` excludes it.
const ROLE_MATCHERS = Object.freeze({
  fast: (id) => /nemotron/i.test(id) && /nano/i.test(id) && !/omni/i.test(id),
  agent: (id) => /nemotron/i.test(id) && /super/i.test(id),
  reasoning: (id) => /nemotron/i.test(id) && /ultra/i.test(id),
  omni: (id) => /omni/i.test(id)
});

const resolvedModels = new Map();

// The configured id for a role, or — after `force` — the one the provider says
// it serves. Model ids are the least certain part of the configuration, so a
// rejected id is looked up rather than left to fail every later call.
export async function resolveModel(role, { config = getProviderConfig(), force = false } = {}) {
  const configured = config.models[role];
  if (!force) return resolvedModels.get(role) || configured;

  const served = await listModels({ config });
  const matcher = ROLE_MATCHERS[role];
  const match = matcher ? served.find(matcher) : null;
  if (!match) {
    console.warn(`[ai] GET /models lists no model for role "${role}"; keeping "${configured}".`);
    return resolvedModels.get(role) || configured;
  }
  resolvedModels.set(role, match);
  console.log(`[ai] resolved "${role}" model via GET /models: ${match}`);
  return match;
}

// Kept for callers that only care about the omni role.
export function resolveOmniModel(options = {}) {
  return resolveModel("omni", options);
}

export function resetProviderCache() {
  resolvedModels.clear();
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
