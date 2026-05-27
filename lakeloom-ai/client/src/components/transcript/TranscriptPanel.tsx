/**
 * TranscriptPanel — displays transcript segments for a capture session.
 *
 * Modes:
 *   1. Historical: fetches completed transcript from /api/captures/:id/transcript
 *   2. Live: connects to SSE stream during active captures, appends in real-time
 *
 * Features:
 *   - Timestamped segments with confidence indicators
 *   - Click-to-seek: clicking a segment emits onSeek(ms) for audio sync
 *   - Highlight-during-play: external currentTimeMs highlights active segment
 *   - Auto-scroll: new live segments scroll into view
 *   - Copy full transcript to clipboard
 *
 * Brand: Databricks semantic tokens, DM Sans typography, WCAG AA contrast.
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { FileText, Copy, Check, Radio, Loader2 } from 'lucide-react';

// ── Types ────────────────────────────────────────────────────────────────────

interface TranscriptSegment {
  event_id: string;
  event_time: string;
  text: string;
  language: string;
  confidence: number | null;
  segment_index: number | null;
  duration_ms: number | null;
  model: string | null;
}

interface TranscriptData {
  capture_session_id: string;
  session_id: string;
  started_at: string;
  state: string;
  segments: TranscriptSegment[];
  total_segments: number;
  total_duration_ms: number;
  language: string;
}

export interface TranscriptPanelProps {
  captureId: string;
  captureState: 'active' | 'completed' | 'cancelled';
  startedAt: string;
  /** Current playback position in ms (for highlight-during-play) */
  currentTimeMs?: number;
  /** Callback when user clicks a segment (for audio seek) */
  onSeek?: (timeMs: number) => void;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function formatTimestamp(eventTime: string, startedAt: string): string {
  const start = new Date(startedAt).getTime();
  const event = new Date(eventTime).getTime();
  const diffMs = Math.max(0, event - start);
  const totalSeconds = Math.floor(diffMs / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

function confidenceColor(confidence: number | null): string {
  if (confidence === null) return 'var(--text-secondary, #5A6F77)';
  if (confidence >= 0.9) return 'var(--accent-success, #00A972)';
  if (confidence >= 0.7) return 'var(--accent-warning, #E68A00)';
  return 'var(--accent-error, #BD2B26)';
}

function getSegmentTimeMs(segment: TranscriptSegment, startedAt: string): number {
  const start = new Date(startedAt).getTime();
  const event = new Date(segment.event_time).getTime();
  return Math.max(0, event - start);
}

// ── Component ────────────────────────────────────────────────────────────────

export function TranscriptPanel({
  captureId,
  captureState,
  startedAt,
  currentTimeMs,
  onSeek,
}: TranscriptPanelProps) {
  const [segments, setSegments] = useState<TranscriptSegment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [liveConnected, setLiveConnected] = useState(false);

  const scrollRef = useRef<HTMLDivElement>(null);
  const autoScrollRef = useRef(true);

  // ── Fetch historical transcript ──────────────────────────────────

  useEffect(() => {
    let cancelled = false;

    async function fetchTranscript() {
      try {
        setLoading(true);
        setError(null);
        const res = await fetch(`/api/captures/${captureId}/transcript`);
        if (!res.ok) {
          if (res.status === 404) {
            setSegments([]);
            return;
          }
          throw new Error(`Failed to fetch transcript: ${res.status}`);
        }
        const data: TranscriptData = await res.json();
        if (!cancelled) {
          setSegments(data.segments);
        }
      } catch (err) {
        if (!cancelled) {
          setError((err as Error).message);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    fetchTranscript();
    return () => { cancelled = true; };
  }, [captureId]);

  // ── SSE live stream (active captures only) ───────────────────────

  useEffect(() => {
    if (captureState !== 'active') return;

    const eventSource = new EventSource(`/api/captures/${captureId}/transcript/stream`);
    
    eventSource.onopen = () => {
      setLiveConnected(true);
    };

    eventSource.addEventListener('transcript', (e) => {
      try {
        const segment: TranscriptSegment = JSON.parse(e.data);
        setSegments((prev) => [...prev, segment]);
        // Auto-scroll to bottom
        if (autoScrollRef.current) {
          setTimeout(() => {
            scrollRef.current?.scrollTo({
              top: scrollRef.current.scrollHeight,
              behavior: 'smooth',
            });
          }, 50);
        }
      } catch { /* ignore malformed events */ }
    });

    eventSource.onerror = () => {
      setLiveConnected(false);
    };

    return () => {
      eventSource.close();
      setLiveConnected(false);
    };
  }, [captureId, captureState]);

  // ── Copy to clipboard ────────────────────────────────────────────

  const handleCopy = useCallback(async () => {
    const fullText = segments.map((s) => s.text).join(' ');
    await navigator.clipboard.writeText(fullText);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [segments]);

  // ── Scroll tracking ──────────────────────────────────────────────

  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    // Disable auto-scroll if user scrolled up
    const isAtBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
    autoScrollRef.current = isAtBottom;
  };

  // ── Active segment detection ─────────────────────────────────────

  const activeSegmentIndex = currentTimeMs != null
    ? segments.findIndex((seg, i) => {
        const segMs = getSegmentTimeMs(seg, startedAt);
        const nextSegMs = i < segments.length - 1
          ? getSegmentTimeMs(segments[i + 1], startedAt)
          : Infinity;
        return currentTimeMs >= segMs && currentTimeMs < nextSegMs;
      })
    : -1;

  // ── Render ───────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="flex items-center gap-2 py-8 justify-center text-sm text-[var(--text-secondary,#5A6F77)]">
        <Loader2 className="w-4 h-4 animate-spin" />
        Loading transcript...
      </div>
    );
  }

  if (error) {
    return (
      <div className="px-4 py-3 rounded-lg border-l-[3px] border-l-[var(--accent-error,#BD2B26)]
                      bg-[var(--accent-error-subtle,#FABFBA)] text-sm text-[var(--text-primary,#1B3139)]">
        {error}
      </div>
    );
  }

  if (segments.length === 0 && captureState !== 'active') {
    return (
      <div className="flex flex-col items-center justify-center py-8 text-center">
        <FileText className="w-8 h-8 text-[var(--text-secondary,#5A6F77)] opacity-50 mb-2" />
        <p className="text-sm text-[var(--text-secondary,#5A6F77)]">No transcript available</p>
        <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-1 opacity-75">
          Transcripts appear when speech is captured during a session.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {/* ── Header ─────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <h3 className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">
            Transcript
          </h3>
          <span className="text-xs text-[var(--text-secondary,#5A6F77)]">
            ({segments.length} {segments.length === 1 ? 'segment' : 'segments'})
          </span>
          {captureState === 'active' && (
            <span className="inline-flex items-center gap-1 text-xs">
              <Radio className={`w-3 h-3 ${liveConnected ? 'text-[var(--accent-success,#00A972)] animate-pulse' : 'text-[var(--text-secondary,#5A6F77)]'}`} />
              <span className={liveConnected ? 'text-[var(--accent-success,#00A972)]' : 'text-[var(--text-secondary,#5A6F77)]'}>
                {liveConnected ? 'Live' : 'Connecting...'}
              </span>
            </span>
          )}
        </div>

        {segments.length > 0 && (
          <button
            type="button"
            onClick={handleCopy}
            className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs
                       text-[var(--text-secondary,#5A6F77)] hover:bg-[var(--surface-tertiary,#EEEDE9)]
                       transition-colors duration-100"
            aria-label="Copy transcript"
          >
            {copied ? <Check className="w-3.5 h-3.5 text-[var(--accent-success,#00A972)]" /> : <Copy className="w-3.5 h-3.5" />}
            {copied ? 'Copied' : 'Copy'}
          </button>
        )}
      </div>

      {/* ── Segments list ─────────────────────────────────────────── */}
      <div
        ref={scrollRef}
        onScroll={handleScroll}
        className="max-h-[400px] overflow-y-auto space-y-1 pr-1
                   scrollbar-thin scrollbar-thumb-[var(--border-default,#DCE0E2)]"
      >
        {segments.map((seg, i) => {
          const isActive = i === activeSegmentIndex;
          const timeMs = getSegmentTimeMs(seg, startedAt);

          return (
            <div
              key={seg.event_id}
              onClick={() => onSeek?.(timeMs)}
              className={`flex items-start gap-3 px-3 py-2 rounded-lg transition-colors duration-150
                ${isActive
                  ? 'bg-[var(--accent-primary-subtle,#E8F4FD)] border border-[var(--accent-primary,#2272B4)]'
                  : 'hover:bg-[var(--surface-tertiary,#EEEDE9)]'
                }
                ${onSeek ? 'cursor-pointer' : ''}`}
              role={onSeek ? 'button' : undefined}
              tabIndex={onSeek ? 0 : undefined}
            >
              {/* Timestamp */}
              <span className="flex-shrink-0 w-10 text-xs font-mono text-[var(--text-secondary,#5A6F77)] pt-0.5 text-right">
                {formatTimestamp(seg.event_time, startedAt)}
              </span>

              {/* Text */}
              <p className="flex-1 text-sm text-[var(--text-primary,#1B3139)] leading-relaxed">
                {seg.text}
              </p>

              {/* Confidence dot */}
              {seg.confidence !== null && (
                <span
                  className="flex-shrink-0 w-2 h-2 rounded-full mt-1.5"
                  style={{ backgroundColor: confidenceColor(seg.confidence) }}
                  title={`Confidence: ${Math.round(seg.confidence * 100)}%`}
                />
              )}
            </div>
          );
        })}

        {/* Live waiting indicator */}
        {captureState === 'active' && segments.length === 0 && (
          <div className="flex items-center gap-2 py-4 justify-center text-sm text-[var(--text-secondary,#5A6F77)]">
            <Loader2 className="w-4 h-4 animate-spin" />
            Waiting for speech...
          </div>
        )}
      </div>
    </div>
  );
}
