import { useCallback, useEffect, useRef, useState } from 'react';
import { Download, Pause, Play, RotateCcw, Volume2, VolumeX } from 'lucide-react';

interface AudioPlayerProps {
  /** Upload ID — used to build the streaming URL */
  uploadId: string;
  /** Display title (original filename or label) */
  title?: string;
  /** File size in bytes (for display) */
  sizeBytes?: number;
  /** Duration in seconds (if known from metadata) */
  durationHint?: number;
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

export function AudioPlayer({ uploadId, title, sizeBytes, durationHint }: AudioPlayerProps) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const animFrameRef = useRef<number>(0);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const sourceRef = useRef<MediaElementAudioSourceNode | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(durationHint ?? 0);
  const [speedIdx, setSpeedIdx] = useState(2); // 1x
  const [isMuted, setIsMuted] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const streamUrl = `/api/media/${uploadId}`;

  // ── Audio context & analyser setup (for waveform) ─────────────────────
  const initAudioContext = useCallback(() => {
    if (audioCtxRef.current || !audioRef.current) return;
    try {
      const ctx = new AudioContext();
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = 0.7;
      const source = ctx.createMediaElementSource(audioRef.current);
      source.connect(analyser);
      analyser.connect(ctx.destination);
      audioCtxRef.current = ctx;
      analyserRef.current = analyser;
      sourceRef.current = source;
    } catch {
      // Web Audio not available — waveform won't render, audio still works
    }
  }, []);

  // ── Waveform rendering ────────────────────────────────────────────────
  const drawWaveform = useCallback(() => {
    const canvas = canvasRef.current;
    const analyser = analyserRef.current;
    if (!canvas || !analyser) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);
    analyser.getByteFrequencyData(dataArray);

    const { width, height } = canvas;
    ctx.clearRect(0, 0, width, height);

    const barWidth = (width / bufferLength) * 2.5;
    let x = 0;

    for (let i = 0; i < bufferLength; i++) {
      const barHeight = (dataArray[i] / 255) * height * 0.8;
      // Lava gradient for active bars
      const intensity = dataArray[i] / 255;
      ctx.fillStyle = intensity > 0.1
        ? `rgba(255, 54, 33, ${0.3 + intensity * 0.7})`
        : 'rgba(144, 165, 177, 0.3)';
      ctx.fillRect(x, height - barHeight, barWidth - 1, barHeight);
      x += barWidth;
    }

    if (isPlaying) {
      animFrameRef.current = requestAnimationFrame(drawWaveform);
    }
  }, [isPlaying]);

  useEffect(() => {
    if (isPlaying && analyserRef.current) {
      drawWaveform();
    }
    return () => {
      if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current);
    };
  }, [isPlaying, drawWaveform]);

  // ── Playback controls ─────────────────────────────────────────────────
  const togglePlay = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    initAudioContext();
    if (audioCtxRef.current?.state === 'suspended') {
      audioCtxRef.current.resume();
    }
    if (isPlaying) {
      audio.pause();
    } else {
      audio.play().catch(() => setError('Playback failed'));
    }
  }, [isPlaying, initAudioContext]);

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

  // ── Audio element event handlers ──────────────────────────────────────
  const handleTimeUpdate = () => setCurrentTime(audioRef.current?.currentTime ?? 0);
  const handleLoadedMetadata = () => {
    setDuration(audioRef.current?.duration ?? 0);
    setIsLoading(false);
  };
  const handlePlay = () => setIsPlaying(true);
  const handlePause = () => setIsPlaying(false);
  const handleError = () => setError('Failed to load audio');
  const handleCanPlay = () => setIsLoading(false);

  const progress = duration > 0 ? (currentTime / duration) * 100 : 0;

  return (
    <div className="bg-[var(--surface-raised)] border border-[var(--border-default)] rounded-xl overflow-hidden">
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
      <div className="relative h-16 bg-[var(--surface-secondary)] border-b border-[var(--border-default)]">
        <canvas
          ref={canvasRef}
          className="absolute inset-0 w-full h-full"
          width={600}
          height={64}
        />
        {/* Progress overlay */}
        <div
          className="absolute inset-y-0 left-0 bg-[var(--accent-primary)] opacity-5 pointer-events-none transition-all duration-100"
          style={{ width: `${progress}%` }}
        />
      </div>

      {/* Controls */}
      <div className="px-4 py-3 flex items-center gap-3">
        {/* Play/Pause */}
        <button
          onClick={togglePlay}
          disabled={isLoading || !!error}
          className="w-9 h-9 flex items-center justify-center rounded-full bg-[var(--accent-primary)] text-white hover:brightness-90 transition-all duration-[var(--motion-fast)] disabled:opacity-50 disabled:cursor-not-allowed"
          aria-label={isPlaying ? 'Pause' : 'Play'}
        >
          {isPlaying ? <Pause className="w-4 h-4" /> : <Play className="w-4 h-4 ml-0.5" />}
        </button>

        {/* Restart */}
        <button
          onClick={restart}
          className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)]"
          aria-label="Restart"
        >
          <RotateCcw className="w-3.5 h-3.5" />
        </button>

        {/* Seek bar */}
        <div
          className="flex-1 h-1.5 bg-[var(--surface-tertiary)] rounded-full cursor-pointer group relative"
          onClick={seekTo}
        >
          <div
            className="absolute inset-y-0 left-0 bg-[var(--accent-primary)] rounded-full transition-all duration-100"
            style={{ width: `${progress}%` }}
          />
          <div
            className="absolute top-1/2 -translate-y-1/2 w-3 h-3 bg-[var(--accent-primary)] rounded-full opacity-0 group-hover:opacity-100 transition-opacity duration-[var(--motion-fast)] shadow-sm"
            style={{ left: `calc(${progress}% - 6px)` }}
          />
        </div>

        {/* Time display */}
        <span className="text-xs font-mono text-[var(--text-secondary)] min-w-[70px] text-right tabular-nums">
          {formatTime(currentTime)} / {formatTime(duration)}
        </span>

        {/* Speed */}
        <button
          onClick={cycleSpeed}
          className="px-2 py-1 text-xs font-medium rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)] min-w-[40px]"
          title="Playback speed"
        >
          {SPEEDS[speedIdx]}x
        </button>

        {/* Mute */}
        <button
          onClick={toggleMute}
          className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)]"
          aria-label={isMuted ? 'Unmute' : 'Mute'}
        >
          {isMuted ? <VolumeX className="w-4 h-4" /> : <Volume2 className="w-4 h-4" />}
        </button>

        {/* Download */}
        <a
          href={streamUrl}
          download={title ?? `${uploadId}`}
          className="w-7 h-7 flex items-center justify-center rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)]"
          aria-label="Download"
        >
          <Download className="w-4 h-4" />
        </a>
      </div>

      {/* Footer info */}
      <div className="px-4 pb-3 flex items-center justify-between">
        {title && (
          <span className="text-xs text-[var(--text-secondary)] truncate max-w-[60%]">{title}</span>
        )}
        {sizeBytes && (
          <span className="text-xs text-[var(--text-tertiary)]">{formatFileSize(sizeBytes)}</span>
        )}
      </div>

      {/* Error state */}
      {error && (
        <div className="px-4 pb-3">
          <p className="text-xs text-[var(--accent-error)]">{error}</p>
        </div>
      )}
    </div>
  );
}
