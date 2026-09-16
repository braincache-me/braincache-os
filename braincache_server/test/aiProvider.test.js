import assert from "node:assert/strict";
import test from "node:test";
import {
  NEBIUS_BASE_URL,
  NEMOTRON_DEFAULTS,
  OPENAI_BASE_URL,
  OPENAI_DEFAULT_MODEL,
  chatCompletion,
  envNumber,
  getProviderConfig,
  listModels,
  messageText,
  messageToolCalls,
  omniChatCompletion,
  repairRejectedBody,
  resetProviderCache,
  stripThinkTags
} from "../server/aiProvider.js";

// --- fetch mock -------------------------------------------------------------

function mockFetch(handler) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), method: init.method || "GET", headers: init.headers || {}, body });
    const result = await handler({ url: String(url), body, index: calls.length - 1 });
    const { status = 200, payload = {} } = result || {};
    return { ok: status >= 200 && status < 300, status, json: async () => payload };
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}

function chatPayload(content, extra = {}) {
  return { choices: [{ message: { role: "assistant", content, ...extra } }] };
}

// --- configuration ----------------------------------------------------------

test("defaults to Nebius Token Factory with the Nemotron model roles", () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });

  assert.equal(config.provider, "nebius");
  assert.equal(config.providerLabel, "Nebius Token Factory");
  assert.equal(config.baseUrl, NEBIUS_BASE_URL);
  assert.equal(config.apiKey, "nk-test");
  assert.equal(config.enabled, true);
  assert.deepEqual(config.models, { ...NEMOTRON_DEFAULTS });
});

test("falls back to OpenAI only when no Nebius or generic key is set", () => {
  const config = getProviderConfig({ OPENAI_API_KEY: "sk-test" });

  assert.equal(config.provider, "openai");
  assert.equal(config.baseUrl, OPENAI_BASE_URL);
  assert.equal(config.models.agent, OPENAI_DEFAULT_MODEL);
  assert.equal(config.models.omni, OPENAI_DEFAULT_MODEL);

  // A Nebius key wins even when an OpenAI key is also present.
  const both = getProviderConfig({ NEBIUS_API_KEY: "nk", OPENAI_API_KEY: "sk" });
  assert.equal(both.provider, "nebius");
  assert.equal(both.apiKey, "nk");
});

test("generic AI_* overrides win over provider-specific env vars", () => {
  const config = getProviderConfig({
    NEBIUS_API_KEY: "nk",
    AI_API_KEY: "generic-key",
    AI_BASE_URL: "https://gateway.internal/v1/",
    NEMOTRON_AGENT_MODEL: "custom/agent",
    NEMOTRON_OMNI_MODEL: "custom/omni",
    AI_MAX_TOOL_ROUNDS: "2",
    AI_MAX_TOOL_CALLS: "3",
    AI_MAX_OUTPUT_TOKENS: "555"
  });

  assert.equal(config.apiKey, "generic-key");
  assert.equal(config.baseUrl, "https://gateway.internal/v1"); // trailing slash trimmed
  assert.equal(config.models.agent, "custom/agent");
  assert.equal(config.models.omni, "custom/omni");
  assert.equal(config.models.fast, NEMOTRON_DEFAULTS.fast);
  assert.deepEqual(
    [config.limits.maxToolRounds, config.limits.maxToolCalls, config.limits.maxOutputTokens],
    [2, 3, 555]
  );
});

test("no key disables AI", () => {
  const config = getProviderConfig({});
  assert.equal(config.enabled, false);
  assert.equal(config.apiKey, "");
});

test("envNumber reads the first defined numeric var, else the fallback", () => {
  assert.equal(envNumber({ B: "7" }, ["A", "B"], 1), 7);
  assert.equal(envNumber({ A: "", B: "not-a-number" }, ["A", "B"], 42), 42);
  assert.equal(envNumber({}, ["A"], 9), 9);
});

// --- transport --------------------------------------------------------------

test("chatCompletion posts to /chat/completions with bearer auth", async () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const fetchMock = mockFetch(() => ({ payload: chatPayload("hello") }));
  try {
    const response = await chatCompletion({ model: "m", messages: [] }, { config });
    assert.equal(messageText(response), "hello");
    assert.equal(fetchMock.calls[0].url, `${NEBIUS_BASE_URL}/chat/completions`);
    assert.equal(fetchMock.calls[0].headers.authorization, "Bearer nk-test");
  } finally {
    fetchMock.restore();
  }
});

test("chatCompletion retries once without optional fields when the server rejects them", async () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const fetchMock = mockFetch(({ index }) => (index === 0
    ? { status: 400, payload: { error: { message: "Unknown parameter: 'top_k'." } } }
    : { payload: chatPayload("ok") }));
  try {
    const response = await chatCompletion({ model: "m", messages: [], top_k: 1 }, { config });
    assert.equal(messageText(response), "ok");
    assert.equal(fetchMock.calls.length, 2);
    assert.ok(!("top_k" in fetchMock.calls[1].body));
  } finally {
    fetchMock.restore();
  }
});

test("repairRejectedBody renames, drops, or gives up", () => {
  const renamed = repairRejectedBody({ model: "m", max_tokens: 100 }, Object.assign(new Error("Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."), { status: 400 }));
  assert.deepEqual(renamed.body, { model: "m", max_completion_tokens: 100 });

  const dropped = repairRejectedBody({ model: "m", temperature: 0.2 }, Object.assign(new Error("Unsupported value: 'temperature' does not support 0.2."), { status: 400 }));
  assert.deepEqual(dropped.body, { model: "m" });

  // Never strip what the request needs, and never repair a non-400.
  assert.equal(repairRejectedBody({ model: "m", messages: [] }, Object.assign(new Error("Invalid 'messages'."), { status: 400 })), null);
  assert.equal(repairRejectedBody({ model: "m", top_k: 1 }, Object.assign(new Error("boom"), { status: 500 })), null);
});

test("chatCompletion retries a renamed field and then succeeds", async () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const fetchMock = mockFetch(({ index }) => {
    if (index === 0) return { status: 400, payload: { error: { message: "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead." } } };
    if (index === 1) return { status: 400, payload: { error: { message: "Unsupported value: 'temperature' does not support 0.2 with this model." } } };
    return { payload: chatPayload("done") };
  });
  try {
    const response = await chatCompletion({ model: "m", messages: [], max_tokens: 100, temperature: 0.2 }, { config });
    assert.equal(messageText(response), "done");
    assert.deepEqual(fetchMock.calls[2].body, { model: "m", messages: [], max_completion_tokens: 100 });
  } finally {
    fetchMock.restore();
  }
});

test("chatCompletion without a key explains which key is missing", async () => {
  await assert.rejects(
    () => chatCompletion({ model: "m", messages: [] }, { config: getProviderConfig({}) }),
    /NEBIUS_API_KEY/
  );
});

test("omni requests rediscover the served model id via GET /models", async () => {
  resetProviderCache();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test", NEMOTRON_OMNI_MODEL: "nvidia/stale-omni" });
  const fetchMock = mockFetch(({ url, body, index }) => {
    if (url.endsWith("/models")) {
      return { payload: { data: [{ id: "nvidia/Nemotron-3-Nano-30B" }, { id: "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning" }] } };
    }
    if (index === 0) {
      assert.equal(body.model, "nvidia/stale-omni");
      return { status: 404, payload: { error: { message: "The model `nvidia/stale-omni` does not exist." } } };
    }
    return { payload: chatPayload("transcript text") };
  });
  try {
    const response = await omniChatCompletion({ messages: [] }, { config });
    assert.equal(messageText(response), "transcript text");
    assert.deepEqual(fetchMock.calls.map((call) => call.url.split("/v1")[1]), [
      "/chat/completions",
      "/models",
      "/chat/completions"
    ]);
    assert.equal(fetchMock.calls[2].body.model, "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning");
  } finally {
    fetchMock.restore();
    resetProviderCache();
  }
});

test("listModels accepts both {data:[{id}]} and a bare array", async () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk" });
  let payload = { data: [{ id: "a" }, { id: "b" }] };
  const fetchMock = mockFetch(() => ({ payload }));
  try {
    assert.deepEqual(await listModels({ config }), ["a", "b"]);
    payload = ["c"];
    assert.deepEqual(await listModels({ config }), ["c"]);
  } finally {
    fetchMock.restore();
  }
});

// --- response helpers -------------------------------------------------------

test("stripThinkTags removes complete and unterminated reasoning blocks", () => {
  assert.equal(stripThinkTags("<think>plan</think>Answer"), "Answer");
  assert.equal(stripThinkTags("<think>a</think>one<think>b</think>two"), "onetwo");
  assert.equal(stripThinkTags("visible<think>cut off here"), "visible");
  assert.equal(stripThinkTags("  plain  "), "plain");
  assert.equal(stripThinkTags(null), "");
});

test("messageText joins array content parts; messageToolCalls is always an array", () => {
  assert.equal(messageText(chatPayload([{ type: "text", text: "a" }, { type: "text", text: "b" }])), "ab");
  assert.equal(messageText({}), "");
  assert.deepEqual(messageToolCalls(chatPayload(null)), []);
  const calls = messageToolCalls(chatPayload("", { tool_calls: [{ id: "c1" }] }));
  assert.deepEqual(calls, [{ id: "c1" }]);
});
