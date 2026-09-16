import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { getProviderConfig } from "../server/aiProvider.js";
import {
  DEFAULT_CHUNK_SECONDS,
  TARGET_SAMPLE_RATE,
  buildWavHeader,
  convertToWav,
  findRecordingFiles,
  isRecordingFile,
  parseWavHeader,
  splitWavIntoChunks,
  transcribeChunk,
  transcriptExists,
  transcriptPathForRecording
} from "../server/transcription.js";

// A silent PCM WAV of `seconds` at the target rate, mono 16-bit.
function makeWav(seconds, { sampleRate = TARGET_SAMPLE_RATE, channels = 1, bitsPerSample = 16 } = {}) {
  const dataLength = Math.round(seconds * sampleRate * channels * (bitsPerSample / 8));
  return Buffer.concat([
    buildWavHeader({ sampleRate, channels, bitsPerSample, dataLength }),
    Buffer.alloc(dataLength)
  ]);
}

test("buildWavHeader and parseWavHeader round-trip", () => {
  const wav = makeWav(2);
  const header = parseWavHeader(wav);

  assert.equal(header.audioFormat, 1);
  assert.equal(header.channels, 1);
  assert.equal(header.sampleRate, TARGET_SAMPLE_RATE);
  assert.equal(header.bitsPerSample, 16);
  assert.equal(header.blockAlign, 2);
  assert.equal(header.dataOffset, 44);
  assert.equal(header.dataLength, 2 * TARGET_SAMPLE_RATE * 2);
});

test("parseWavHeader rejects non-WAV, headerless and non-PCM data", () => {
  assert.throws(() => parseWavHeader(Buffer.from("not audio")), /too short|RIFF/);
  assert.throws(() => parseWavHeader(Buffer.concat([Buffer.from("RIFF0000WAVE")])), /no data chunk/);

  const wav = makeWav(1);
  wav.writeUInt16LE(3, 20); // IEEE float instead of PCM
  assert.throws(() => parseWavHeader(wav), /only PCM/);
});

test("parseWavHeader clamps a streaming writer's unknown data size to the file", () => {
  const wav = makeWav(1);
  wav.writeUInt32LE(0xffffffff, 40);
  assert.equal(parseWavHeader(wav).dataLength, wav.length - 44);
});

test("splitWavIntoChunks cuts on frame boundaries and rewrites each header", () => {
  const chunks = splitWavIntoChunks(makeWav(25), { chunkSeconds: 10 });

  assert.deepEqual(chunks.map((chunk) => Math.round(chunk.seconds)), [10, 10, 5]);
  assert.deepEqual(chunks.map((chunk) => chunk.index), [0, 1, 2]);
  for (const chunk of chunks) {
    const header = parseWavHeader(chunk.buffer);
    assert.equal(header.sampleRate, TARGET_SAMPLE_RATE);
    assert.equal(header.dataOffset, 44);
    assert.equal(header.dataLength % header.blockAlign, 0);
    assert.equal(chunk.buffer.length, 44 + header.dataLength);
  }
  assert.equal(chunks.reduce((sum, chunk) => sum + chunk.seconds, 0), 25);
});

test("splitWavIntoChunks keeps a short recording as a single chunk", () => {
  const chunks = splitWavIntoChunks(makeWav(3), { chunkSeconds: DEFAULT_CHUNK_SECONDS });
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].seconds, 3);
});

test("splitWavIntoChunks handles stereo block alignment", () => {
  const chunks = splitWavIntoChunks(makeWav(4, { channels: 2 }), { chunkSeconds: 1 });
  assert.equal(chunks.length, 4);
  assert.ok(chunks.every((chunk) => parseWavHeader(chunk.buffer).channels === 2));
});

test("recording extensions and transcript paths", () => {
  assert.equal(isRecordingFile("meeting.m4a"), true);
  assert.equal(isRecordingFile("Standup.MOV"), true);
  assert.equal(isRecordingFile("notes.txt"), false);
  assert.equal(transcriptPathForRecording("2026-05-05/meeting_22-09-21.m4a"), "2026-05-05/meeting_22-09-21.txt");
  assert.equal(transcriptPathForRecording("\\2026-05-05\\call.mov"), "2026-05-05/call.txt");
  assert.equal(transcriptPathForRecording("noext"), "noext.txt");
});

test("findRecordingFiles walks recordings/ and transcriptExists sees written transcripts", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "braincache-test-"));
  try {
    await fs.mkdir(path.join(root, "recordings", "2026-05-05"), { recursive: true });
    await fs.writeFile(path.join(root, "recordings", "2026-05-05", "call.m4a"), "audio");
    await fs.writeFile(path.join(root, "recordings", "readme.txt"), "ignored");

    const found = await findRecordingFiles(root);
    assert.deepEqual(found.map((file) => file.path), [path.join("2026-05-05", "call.m4a")]);

    assert.equal(await transcriptExists(root, "2026-05-05/call.m4a"), false);
    await fs.mkdir(path.join(root, "transcripts", "2026-05-05"), { recursive: true });
    await fs.writeFile(path.join(root, "transcripts", "2026-05-05", "call.txt"), "hello");
    assert.equal(await transcriptExists(root, "2026-05-05/call.m4a"), true);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("findRecordingFiles returns nothing when the folder is missing", async () => {
  assert.deepEqual(await findRecordingFiles(path.join(os.tmpdir(), "braincache-not-here")), []);
});

test("convertToWav passes an existing WAV through when no converter is installed", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "braincache-test-"));
  try {
    const input = path.join(dir, "audio.wav");
    await fs.writeFile(input, makeWav(1));
    const output = await convertToWav(input, path.join(dir, "out.wav"), { converters: [] });
    assert.equal(output, input);

    const mp3 = path.join(dir, "audio.mp3");
    await fs.writeFile(mp3, "not really audio");
    await assert.rejects(() => convertToWav(mp3, path.join(dir, "out2.wav"), { converters: [] }), /install ffmpeg/);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("transcribeChunk sends the WAV as an audio_url data URI and strips think tags", async () => {
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const original = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, init = {}) => {
    requests.push({ url: String(url), body: JSON.parse(init.body) });
    return {
      ok: true,
      status: 200,
      json: async () => ({ model: config.models.omni, choices: [{ message: { content: "<think>listening</think>Hello team." } }] })
    };
  };
  try {
    const result = await transcribeChunk(makeWav(1), { config });
    assert.equal(result.text, "Hello team.");
    assert.equal(result.model, config.models.omni);

    const parts = requests[0].body.messages[0].content;
    assert.equal(parts[0].type, "audio_url");
    assert.match(parts[0].audio_url.url, /^data:audio\/wav;base64,[A-Za-z0-9+/=]+$/);
    assert.equal(parts[1].type, "text");
  } finally {
    globalThis.fetch = original;
  }
});
