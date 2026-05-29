/**
 * Server-side audio transcode service — CAF/AIFF → M4A (AAC).
 *
 * When iOS's on-device AVAssetExportSession transcode fails (e.g.,
 * AVError.operationInterrupted), the device uploads the raw .caf file.
 * This service transcodes it to browser-playable M4A using ffmpeg.
 *
 * ffmpeg is installed as a static binary by scripts/install-ffmpeg.sh
 * during the prestart lifecycle hook.
 *
 * Transcode parameters:
 *   - Codec: AAC-LC (universally supported by browsers)
 *   - Bitrate: 128 kbps (sufficient for voice/speech recording)
 *   - Channels: mono (speech is mono; halves file size)
 *   - Container: M4A with faststart (moov atom at beginning for HTTP streaming)
 *   - Timeout: 60 seconds (generous for 5–50 MB voice files)
 */

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, statSync } from 'node:fs';
import { unlink } from 'node:fs/promises';

const execFileAsync = promisify(execFile);

/** Path to the ffmpeg binary — set by install-ffmpeg.sh */
const FFMPEG_PATH = process.env.FFMPEG_PATH ?? '/tmp/ffmpeg';

/** Maximum transcode duration before timeout (ms) */
const TRANSCODE_TIMEOUT_MS = 60_000;

// ── Types ────────────────────────────────────────────────────────────────────────

export interface TranscodeResult {
  /** Local filesystem path to the output M4A file */
  outputPath: string;
  /** Transcode wall-clock duration in milliseconds */
  durationMs: number;
  /** Output codec identifier */
  codec: 'aac';
  /** Output file size in bytes */
  outputSizeBytes: number;
}

export interface TranscodeError {
  /** Whether the error is retryable (timeout, transient I/O) vs permanent (corrupt input) */
  retryable: boolean;
  /** Human-readable error message */
  message: string;
  /** Raw ffmpeg stderr output (truncated) */
  stderr?: string;
}

// ── MIME detection ───────────────────────────────────────────────────────────────

/** MIME types that require server-side transcode for browser playback */
const TRANSCODE_REQUIRED_MIMES = new Set([
  'audio/x-caf',
  'audio/x-aiff',
  'audio/aiff',
]);

/**
 * Check if a MIME type requires server-side transcode for browser playback.
 */
export function requiresTranscode(mimeType: string): boolean {
  return TRANSCODE_REQUIRED_MIMES.has(mimeType);
}

/**
 * Whether ffmpeg is installed and available for transcode operations.
 * Checked at startup and before each transcode attempt.
 */
export function isTranscodeAvailable(): boolean {
  return existsSync(FFMPEG_PATH);
}

// ── Transcode ────────────────────────────────────────────────────────────────────

/**
 * Transcode a CAF or AIFF audio file to M4A (AAC LC, 128kbps, mono).
 *
 * @param inputPath - Local filesystem path to the source audio file
 * @param outputPath - Local filesystem path for the output M4A file
 * @returns TranscodeResult on success
 * @throws Error with TranscodeError-shaped message on failure
 *
 * Both inputPath and outputPath should be in /tmp/ (container-local).
 * Caller is responsible for cleanup of both files after upload to volume.
 */
export async function transcodeToM4A(
  inputPath: string,
  outputPath: string,
): Promise<TranscodeResult> {
  if (!isTranscodeAvailable()) {
    throw Object.assign(
      new Error('ffmpeg not available — install via scripts/install-ffmpeg.sh prestart hook'),
      { retryable: false } as TranscodeError,
    );
  }

  if (!existsSync(inputPath)) {
    throw Object.assign(
      new Error(`Transcode input file not found: ${inputPath}`),
      { retryable: false } as TranscodeError,
    );
  }

  const args = [
    '-i', inputPath,
    '-codec:a', 'aac',          // AAC-LC codec
    '-b:a', '128k',             // 128 kbps bitrate (voice quality)
    '-ac', '1',                 // Mono channel (speech recording)
    '-movflags', '+faststart',  // Moov atom at file start for HTTP streaming
    '-y',                       // Overwrite output if exists
    outputPath,
  ];

  const startMs = Date.now();

  try {
    await execFileAsync(FFMPEG_PATH, args, {
      timeout: TRANSCODE_TIMEOUT_MS,
      maxBuffer: 5 * 1024 * 1024, // 5 MB stderr buffer for verbose ffmpeg output
    });
  } catch (err: unknown) {
    const execErr = err as { killed?: boolean; signal?: string; stderr?: string; code?: number };
    const durationMs = Date.now() - startMs;

    // Timeout — ffmpeg was killed
    if (execErr.killed || execErr.signal === 'SIGTERM') {
      throw Object.assign(
        new Error(`Transcode timed out after ${TRANSCODE_TIMEOUT_MS}ms (duration: ${durationMs}ms)`),
        { retryable: true, stderr: execErr.stderr?.slice(-500) } as TranscodeError,
      );
    }

    // ffmpeg returned non-zero exit code
    const stderr = execErr.stderr?.slice(-1000) ?? '';
    throw Object.assign(
      new Error(`Transcode failed (exit code ${execErr.code}): ${stderr.slice(0, 200)}`),
      { retryable: false, stderr } as TranscodeError,
    );
  }

  const durationMs = Date.now() - startMs;

  // Verify output file exists and has content
  if (!existsSync(outputPath)) {
    throw Object.assign(
      new Error('Transcode produced no output file'),
      { retryable: false } as TranscodeError,
    );
  }

  const outputStat = statSync(outputPath);
  if (outputStat.size === 0) {
    throw Object.assign(
      new Error('Transcode produced empty output file'),
      { retryable: false } as TranscodeError,
    );
  }

  return {
    outputPath,
    durationMs,
    codec: 'aac',
    outputSizeBytes: outputStat.size,
  };
}

/**
 * Clean up temporary transcode files.
 * Silently ignores ENOENT (file already deleted).
 */
export async function cleanupTempFiles(...paths: string[]): Promise<void> {
  await Promise.allSettled(
    paths.map((p) => unlink(p).catch(() => undefined)),
  );
}
