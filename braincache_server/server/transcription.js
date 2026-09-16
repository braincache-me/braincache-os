// Meeting-recording transcription with NVIDIA Nemotron 3 Nano Omni on Nebius
// Token Factory. There is no /audio/transcriptions endpoint there — audio goes
// to the omni model through Chat Completions as an `audio_url` data URI.
//
// Pipeline: recording (.m4a/.mov/.mp3/.wav/.caf) → 16 kHz mono 16-bit WAV
// (afconvert on macOS, ffmpeg elsewhere) → ≤10-minute WAV chunks (raw PCM
// split, headers rewritten in JS) → one omni request per chunk → joined text
// written to <activityRoot>/transcripts/<same relative path>.txt so the
// agent's `read_transcript` tool and the UI can find it.

import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { getProviderConfig, messageText, omniChatCompletion, stripThinkTags } from "./aiProvider.js";

const run = promisify(execFile);

export { stripThinkTags };

export const RECORDING_EXTENSIONS = new Set([".m4a", ".mov", ".mp3", ".wav", ".caf", ".mp4", ".aac", ".aiff", ".aif"]);
export const TRANSCRIBE_PROMPT = "Transcribe this audio verbatim. Output only the transcript.";
export const DEFAULT_CHUNK_SECONDS = 600;
export const TARGET_SAMPLE_RATE = 16000;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Transcribe one recording. `relativePath` is the path relative to
// <activityRoot>/recordings/ (what events store in `audioPath`); the transcript
// lands at <activityRoot>/transcripts/<relativePath with .txt>.
export async function transcribeRecording(filePath, {
  emit = async () => {},
  activityRoot = null,
  relativePath = null,
  chunkSeconds,
  config = getProviderConfig(),
  timeoutMs
} = {}) {
  const startedAt = Date.now();
  const name = path.basename(filePath);
  const perChunk = Math.max(30, Number(chunkSeconds) || config.limits.transcribeChunkSeconds || DEFAULT_CHUNK_SECONDS);
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "braincache-transcribe-"));

  try {
    await emit({ type: "thinking", message: `Converting ${name} to 16 kHz mono WAV…` });
    const wavPath = await convertToWav(filePath, path.join(workDir, "audio.wav"));
    const wav = await fs.readFile(wavPath);
    const chunks = splitWavIntoChunks(wav, { chunkSeconds: perChunk });
    const totalSeconds = chunks.reduce((sum, chunk) => sum + chunk.seconds, 0);
    if (!chunks.length || totalSeconds < 0.5) {
      throw new Error(`${name} contains no audio to transcribe.`);
    }

    await emit({
      type: "thinking",
      message: `Sending ${formatSeconds(totalSeconds)} of audio to ${config.models.omni} in ${chunks.length} chunk(s)…`
    });

    const parts = [];
    let model = config.models.omni;
    for (const [index, chunk] of chunks.entries()) {
      await emit({ type: "thinking", message: `Transcribing chunk ${index + 1}/${chunks.length} (${formatSeconds(chunk.seconds)})…` });
      const result = await transcribeChunk(chunk.buffer, { config, timeoutMs });
      model = result.model || model;
      parts.push(result.text);
    }

    const text = parts.map((part) => part.trim()).filter(Boolean).join("\n\n");
    let transcriptPath = null;
    if (activityRoot) {
      transcriptPath = transcriptPathForRecording(relativePath || name);
      const target = path.join(path.resolve(activityRoot), "transcripts", transcriptPath);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, text, "utf8");
    }

    return {
      text,
      chunks: chunks.length,
      model,
      seconds: Math.round(totalSeconds),
      transcriptPath,
      elapsedMs: Date.now() - startedAt
    };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true });
  }
}

// One omni request for a WAV buffer. Model-card ASR settings: non-thinking,
// low temperature, top_k 1 (extras are dropped on retry if the server rejects them).
export async function transcribeChunk(wavBuffer, { config = getProviderConfig(), timeoutMs } = {}) {
  const response = await omniChatCompletion({
    messages: [
      {
        role: "user",
        content: [
          { type: "audio_url", audio_url: { url: `data:audio/wav;base64,${wavBuffer.toString("base64")}` } },
          { type: "text", text: TRANSCRIBE_PROMPT }
        ]
      }
    ],
    temperature: 0.2,
    top_k: 1,
    max_tokens: 8192,
    chat_template_kwargs: { enable_thinking: false }
  }, { config, timeoutMs: timeoutMs ?? config.limits.transcribeTimeoutMs });
  return { text: stripThinkTags(messageText(response)), model: response?.model || null };
}

// Recursively list recording files under <activityRoot>/recordings/, as paths
// relative to that folder (the same shape events store in `audioPath`).
export async function findRecordingFiles(activityRoot) {
  const root = path.join(path.resolve(activityRoot), "recordings");
  const found = [];
  async function walk(dir) {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (isRecordingFile(entry.name)) {
        const stat = await fs.stat(full);
        found.push({ path: path.relative(root, full), size: stat.size, modifiedAt: stat.mtime.toISOString() });
      }
    }
  }
  await walk(root);
  return found.sort((a, b) => a.path.localeCompare(b.path));
}

export function isRecordingFile(name) {
  return RECORDING_EXTENSIONS.has(path.extname(String(name || "")).toLowerCase());
}

// recordings/2026-05-05/meeting_22-09-21.m4a → 2026-05-05/meeting_22-09-21.txt
export function transcriptPathForRecording(relativePath) {
  const normalized = String(relativePath || "").replace(/\\/g, "/").replace(/^\/+/, "");
  const ext = path.posix.extname(normalized);
  return (ext ? normalized.slice(0, -ext.length) : normalized) + ".txt";
}

export async function transcriptExists(activityRoot, relativePath) {
  const target = path.join(path.resolve(activityRoot), "transcripts", transcriptPathForRecording(relativePath));
  try {
    const stat = await fs.stat(target);
    return stat.isFile() && stat.size > 0;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Conversion — afconvert (macOS) → ffmpeg → WAV passthrough
// ---------------------------------------------------------------------------

const CONVERTERS = [
  {
    name: "afconvert",
    args: (input, output) => ["-f", "WAVE", "-d", `LEI16@${TARGET_SAMPLE_RATE}`, "-c", "1", input, output]
  },
  {
    name: "ffmpeg",
    args: (input, output) => ["-y", "-loglevel", "error", "-i", input, "-vn", "-ac", "1", "-ar", String(TARGET_SAMPLE_RATE), "-acodec", "pcm_s16le", "-f", "wav", output]
  }
];

export async function convertToWav(inputPath, outputPath, { converters = CONVERTERS } = {}) {
  const failures = [];
  for (const converter of converters) {
    try {
      await run(converter.name, converter.args(inputPath, outputPath), { maxBuffer: 1024 * 1024 });
      const wav = await fs.readFile(outputPath);
      parseWavHeader(wav); // throws if the tool produced something unexpected
      return outputPath;
    } catch (error) {
      failures.push(`${converter.name}: ${error.code === "ENOENT" ? "not installed" : (error.stderr || error.message).toString().trim()}`);
    }
  }

  if (path.extname(inputPath).toLowerCase() === ".wav") {
    const wav = await fs.readFile(inputPath);
    const header = parseWavHeader(wav);
    if (header.sampleRate < 8000) {
      throw new Error(`${path.basename(inputPath)} is sampled at ${header.sampleRate} Hz; the omni model needs at least 8 kHz.`);
    }
    return inputPath;
  }

  throw new Error(
    `Cannot convert ${path.basename(inputPath)} to WAV — install ffmpeg (or use macOS afconvert), or provide a .wav file. ` +
      `Tried: ${failures.join("; ")}.`
  );
}

// ---------------------------------------------------------------------------
// WAV helpers (pure)
// ---------------------------------------------------------------------------

// Parse a RIFF/WAVE header. Returns the PCM format and where the samples live.
export function parseWavHeader(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) throw new Error("Not a WAV file (too short).");
  if (buffer.toString("ascii", 0, 4) !== "RIFF" || buffer.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error("Not a WAV file (missing RIFF/WAVE header).");
  }

  let format = null;
  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString("ascii", offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    const bodyStart = offset + 8;
    if (id === "fmt ") {
      const audioFormat = buffer.readUInt16LE(bodyStart);
      format = {
        audioFormat,
        channels: buffer.readUInt16LE(bodyStart + 2),
        sampleRate: buffer.readUInt32LE(bodyStart + 4),
        blockAlign: buffer.readUInt16LE(bodyStart + 12),
        bitsPerSample: buffer.readUInt16LE(bodyStart + 14)
      };
      if (audioFormat === 0xfffe && size >= 26) {
        // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format GUID's first two bytes.
        format.audioFormat = buffer.readUInt16LE(bodyStart + 24);
      }
    } else if (id === "data") {
      if (!format) throw new Error("WAV data chunk appears before fmt chunk.");
      if (format.audioFormat !== 1) throw new Error(`Unsupported WAV encoding (format ${format.audioFormat}); only PCM is supported.`);
      // Streaming writers may leave the size as 0 / 0xFFFFFFFF — clamp to the file.
      const available = buffer.length - bodyStart;
      const dataLength = size === 0 || size === 0xffffffff || size > available ? available : size;
      return { ...format, dataOffset: bodyStart, dataLength };
    }
    offset = bodyStart + size + (size % 2); // chunks are word-aligned
  }
  throw new Error("WAV file has no data chunk.");
}

// Build a canonical 44-byte PCM WAV header.
export function buildWavHeader({ sampleRate, channels, bitsPerSample, dataLength }) {
  const blockAlign = channels * (bitsPerSample / 8);
  const header = Buffer.alloc(44);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(36 + dataLength, 4);
  header.write("WAVE", 8, "ascii");
  header.write("fmt ", 12, "ascii");
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * blockAlign, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write("data", 36, "ascii");
  header.writeUInt32LE(dataLength, 40);
  return header;
}

// Split a PCM WAV into standalone WAV buffers of at most `chunkSeconds` each.
export function splitWavIntoChunks(buffer, { chunkSeconds = DEFAULT_CHUNK_SECONDS } = {}) {
  const header = parseWavHeader(buffer);
  const { sampleRate, channels, bitsPerSample, blockAlign, dataOffset, dataLength } = header;
  const bytesPerSecond = sampleRate * blockAlign;
  if (!bytesPerSecond) throw new Error("WAV header has a zero sample rate or block size.");
  const chunkBytes = Math.max(blockAlign, Math.floor((chunkSeconds * bytesPerSecond) / blockAlign) * blockAlign);
  const data = buffer.subarray(dataOffset, dataOffset + dataLength);

  const chunks = [];
  for (let start = 0; start < data.length; start += chunkBytes) {
    const slice = data.subarray(start, Math.min(data.length, start + chunkBytes));
    const usable = slice.length - (slice.length % blockAlign);
    if (!usable) break;
    const body = slice.subarray(0, usable);
    chunks.push({
      index: chunks.length,
      seconds: usable / bytesPerSecond,
      buffer: Buffer.concat([buildWavHeader({ sampleRate, channels, bitsPerSample, dataLength: usable }), body])
    });
  }
  return chunks;
}

function formatSeconds(seconds) {
  const total = Math.round(seconds);
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  return minutes ? `${minutes}m ${rest}s` : `${rest}s`;
}
