import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { AlertCircle, Download, Pause, Play, RotateCcw, Volume2, VolumeX } from 'lucide-react';

export interface AudioPlayerHandle {
  /** Seek to a specific time in milliseconds */
  seekTo(timeMs: number): void;
}

interface AudioPlayerProps {
  /** Upload ID — used to build the streaming URL */
  uploadId: string;
  /** Display title (original filename or label) */
  title?: string;
  /** File size in bytes (for display) */
  sizeBytes?: number;
  /** Duration in seconds (if known from metadata) */
  durationHint?: number;
  /** Called on every timeupdate with current position in milliseconds */
  onTimeUpdate?: (timeMs: number) => void;
}

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;

function formatTime(seconds: number): string {
  if (!isFinite(seconds) || seconds < 0) return '0:00';
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * Generates a deterministic pseudo-random waveform shape for static visualization.
 * Seeded by uploadId so the same file always looks the same.
 */
function generateWaveformBars(uploadId: string, count: number): number[] {
  let hash = 0;
  for (let i = 0; i < uploadId.length; i++) {
    hash = ((hash << 5) - hash + uploadId.charCodeAt(i)) | 0;
  }
  const bars: number[] = [];
  for (let i = 0; i < count; i++) {
    hash = (hash * 1664525 + 1013904223) | 0;
    const normalized = (Math.abs(hash) % 1000) / 1000;
    const envelope = Math.sin((i / count) * Math.PI) * 0.6 + 0.4;
    bars.push(normalized * envelope * 0.85 + 0.1);
  }
  return bars;
}

export const AudioPlayer = forwardRef<AudioPlayerHandle, AudioPlayerProps>(
  function AudioPlayer({ uploadId, title, sizeBytes, durationHint, onTimeUpdate }, ref) {
    const audioRef = useRef<HTMLAudioElement>(null);
    const canvasRef = useRef<HTMLCanvasElement>(null);
    const animFrameRef = useRef<number>(0);

    const [isPlaying, setIsPlaying] = useState(false);
    const [currentTime, setCurrentTime] = useState(0);
    const [duration, setDuration] = useState(durationHint ?? 0);
    const [speedIdx, setSpeedIdx] = useState(2); // 1x
    const [isMuted, setIsMuted] = useState(false);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const streamUrl = `/api/media/${uploadId}`;

    // Pre-compute static waveform shape (deterministic per upload)
    const waveformBars = useRef(generateWaveformBars(uploadId, 80)).current;

    // ── Expose imperative handle for external seek ─────────────────────
    useImperativeHandle(ref, () => ({
      seekTo(timeMs: number) {
        const audio = audioRef.current;
        if (audio) {
          audio.currentTime = timeMs / 1000;
        }
      },
    }), []);

    // ── Waveform rendering (static shape + progress overlay) ─────────────
    const drawWaveform = useCallback(() => {
      const canvas = canvasRef.current;
      if (!canvas) return;

      const ctx = canvas.getContext('2d');
      if (!ctx) return;

      const { width, height } = canvas;
      ctx.clearRect(0, 0, width, height);

      const barCount = waveformBars.length;
      const barWidth = width / barCount;
      const progressRatio = duration > 0 ? currentTime / duration : 0;

      for (let i = 0; i < barCount; i++) {
        const barHeight = waveformBars[i] * height * 0.85;
        const x = i * barWidth;
        const barProgress = (i + 0.5) / barCount;

        if (barProgress <= progressRatio) {
          ctx.fillStyle = 'rgba(255, 54, 33, 0.85)';
        } else {
          ctx.fillStyle = 'rgba(144, 165, 177, 0.35)';
        }

        const y = (height - barHeight) / 2;
        ctx.fillRect(x + 1, y, barWidth - 2, barHeight);
      }

      if (isPlaying) {
        animFrameRef.current = requestAnimationFrame(drawWaveform);
      }
    }, [isPlaying, currentTime, duration, waveformBars]);

    useEffect(() => {
      drawWaveform();
      return () => {
        if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current);
      };
    }, [drawWaveform]);

    // ── Playback controls ─────────────────────────────────────────────
    const togglePlay = useCallback(() => {
      const audio = audioRef.current;
      if (!audio) return;
      if (isPlaying) {
        audio.pause();
      } else {
        audio.play().catch(() => setError('Playback failed'));
      }
    }, [isPlaying]);

    const cycleSpeed = useCallback(() => {
      const nextIdx = (speedIdx + 1) % SPEEDS.length;
      setSpeedIdx(nextIdx);
      if (audioRef.current) {
        audioRef.current.playbackRate = SPEEDS[nextIdx];
      }
    }, [speedIdx]);

    const toggleMute = useCallback(() => {
      if (audioRef.current) {
        audioRef.current.muted = !isMuted;
        setIsMuted(!isMuted);
      }
    }, [isMuted]);

    const seekTo = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
      const audio = audioRef.current;
      if (!audio || !duration) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      audio.currentTime = ratio * duration;
    }, [duration]);

    const restart = useCallback(() => {
      if (audioRef.current) {
        audioRef.current.currentTime = 0;
        if (!isPlaying) audioRef.current.play().catch(() => {});
      }
    }, [isPlaying]);

    // ── Audio element event handlers ──────────────────────────────────
    const handleTimeUpdate = () => {
      const time = audioRef.current?.currentTime ?? 0;
      setCurrentTime(time);
      onTimeUpdate?.(time * 1000); // emit in milliseconds
    };
    const handleLoadedMetadata = () => {
      setDuration(audioRef.current?.duration ?? 0);
      setIsLoading(false);
    };
    const handlePlay = () => setIsPlaying(true);
    const handlePause = () => setIsPlaying(false);
    const handleError = () => {
      const audio = audioRef.current;
      if (audio?.error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED) {
        setError('format-unsupported');
      } else {
        setError('Failed to load audio');
      }
    };
    const handleCanPlay = () => setIsLoading(false);

    const progress = duration > 0 ? (currentTime / duration) * 100 : 0;

    return (
      <div className="bg-[var(--surface-raised,#fff)] border border-[var(--border-default,#DCE0E2)] rounded-xl overflow-hidden">
        {/* Hidden audio element */}
        <audio
          ref={audioRef}
          src={streamUrl}
          preload="metadata"
          onTimeUpdate={handleTimeUpdate}
          onLoadedMetadata={handleLoadedMetadata}
          onPlay={handlePlay}
          onPause={handlePause}
          onError={handleError}
          onCanPlay={handleCanPlay}
        />

        {/* Waveform visualization */}
        <div
          className="relative h-16 bg-[var(--surface-secondary,#F5F5F2)] border-b border-[var(--border-default,#DCE0E2)] cursor-pointer"
          onClick={seekTo}
        >
          <canvas
            ref={canvasRef}
            className="absolute inset-0 w-full h-full"
            width={600}
            height={64}
          />
        </div>

        {/* Controls */}
        <div className="px-4 py-3 flex items-center gap-3">
          <button
            onClick={togglePlay}
            disabled={isLoading || !!error}
            className="w-9 h-9 flex items-center justify-center rounded-full bg-[var(--accent-primary,#FF3621)] text-white hover:brightness-90 transition-all duration-[var(--motion-fast,100ms)] disabled:opacity-50 disabled:cursor-not-allowed"
            aria-label={isPlaying ? 'Pause' : 'Play'}
          >
            {isPlaying ? <Pause className="w-4 h-4" /> : <Play className="w-4 h-4 ml-0.5" />}
          </button>

          <button
            onClick={restart}
            className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-[var(--motion-fast,100ms)]"
            aria-label="Restart"
          >
            <RotateCcw className="w-3.5 h-3.5" />
          </button>

          <div
            className="flex-1 h-1.5 bg-[var(--surface-tertiary,#EEEDE9)] rounded-full cursor-pointer group relative"
            onClick={seekTo}
          >
            <div
              className="absolute inset-y-0 left-0 bg-[var(--accent-primary,#FF3621)] rounded-full transition-all duration-100"
              style={{ width: `${progress}%` }}
            />
            <div
              className="absolute top-1/2 -translate-y-1/2 w-3 h-3 bg-[var(--accent-primary,#FF3621)] rounded-full opacity-0 group-hover:opacity-100 transition-opacity duration-[var(--motion-fast,100ms)] shadow-sm"
              style={{ left: `calc(${progress}% - 6px)` }}
            />
          </div>

          <span className="text-xs font-mono text-[var(--text-secondary,#5A6F77)] min-w-[70px] text-right tabular-nums">
            {formatTime(currentTime)} / {formatTime(duration)}
          </span>

          <button
            onClick={cycleSpeed}
            className="px-2 py-1 text-xs font-medium rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-[var(--motion-fast,100ms)] tabular-nums"
            aria-label="Playback speed"
          >
            {SPEEDS[speedIdx]}x
          </button>

          <button
            onClick={toggleMute}
            className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-[var(--motion-fast,100ms)]"
            aria-label={isMuted ? 'Unmute' : 'Mute'}
          >
            {isMuted ? <VolumeX className="w-3.5 h-3.5" /> : <Volume2 className="w-3.5 h-3.5" />}
          </button>

          <a
            href={streamUrl}
            download={title}
            className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-[var(--motion-fast,100ms)]"
            aria-label="Download"
          >
            <Download className="w-3.5 h-3.5" />
          </a>
        </div>

        {/* Footer: title + file size */}
        <div className="px-4 pb-3 flex items-center justify-between">
          <span className="text-xs text-[var(--text-secondary,#5A6F77)] truncate max-w-[60%]">
            {title ?? 'Audio recording'}
          </span>
          {sizeBytes && (
            <span className="text-xs text-[var(--text-tertiary,#90A5B1)]">
              {formatFileSize(sizeBytes)}
            </span>
          )}
        </div>

        {/* Error state */}
        {error === 'format-unsupported' && (
          <div className="px-4 pb-3">
            <div className="flex items-center gap-2 px-3 py-2.5 rounded-lg bg-[var(--surface-secondary,#F5F5F2)] text-sm text-[var(--text-secondary,#5A6F77)]">
              <AlertCircle className="w-4 h-4 flex-shrink-0" />
              <span>Audio format not playable in browser.</span>
              <a
                href={streamUrl}
                download={title}
                className="ml-auto text-[var(--accent-primary,#FF3621)] underline text-xs font-medium"
              >
                Download
              </a>
            </div>
          </div>
        )}
        {error && error !== 'format-unsupported' && (
          <div className="px-4 pb-3">
            <p className="text-xs text-[var(--accent-error,#BD2B26)]">{error}</p>
          </div>
        )}
      </div>
    );
  }
);
