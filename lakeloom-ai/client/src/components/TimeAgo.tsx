/**
 * TimeAgo — relative time display with auto-refresh.
 *
 * Renders "3 minutes ago", "2 hours ago", etc. Refreshes on an interval
 * appropriate to the time delta (every minute for recent, less often for older).
 * Also computes and displays duration between two ISO timestamps.
 */

import { useState, useEffect } from 'react';
import { cn } from '../lib/utils';

// ── Time formatting helpers ──────────────────────────────────────────────────

const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

function formatRelative(date: Date): string {
  const now = Date.now();
  const diff = now - date.getTime();

  if (diff < MINUTE) return 'just now';
  if (diff < HOUR) {
    const mins = Math.floor(diff / MINUTE);
    return `${mins}m ago`;
  }
  if (diff < DAY) {
    const hours = Math.floor(diff / HOUR);
    return `${hours}h ago`;
  }
  if (diff < DAY * 7) {
    const days = Math.floor(diff / DAY);
    return `${days}d ago`;
  }

  // Beyond a week, show the date
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function formatDuration(startMs: number, endMs: number): string {
  const diff = endMs - startMs;
  if (diff < MINUTE) return '< 1 min';
  if (diff < HOUR) {
    const mins = Math.floor(diff / MINUTE);
    return `${mins} min`;
  }
  const hours = Math.floor(diff / HOUR);
  const mins = Math.floor((diff % HOUR) / MINUTE);
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}

function getRefreshInterval(date: Date): number {
  const diff = Date.now() - date.getTime();
  if (diff < HOUR) return 30_000;       // refresh every 30s for recent
  if (diff < DAY) return 5 * MINUTE;    // every 5 min for today
  return 60 * MINUTE;                   // every hour for older
}

// ── TimeAgo component ────────────────────────────────────────────────────────

interface TimeAgoProps {
  /** ISO 8601 timestamp */
  date: string;
  className?: string;
}

export function TimeAgo({ date, className }: TimeAgoProps) {
  const dateObj = new Date(date);
  const [display, setDisplay] = useState(() => formatRelative(dateObj));

  useEffect(() => {
    const interval = setInterval(
      () => setDisplay(formatRelative(dateObj)),
      getRefreshInterval(dateObj),
    );
    return () => clearInterval(interval);
  }, [date]);

  return (
    <time
      dateTime={date}
      title={dateObj.toLocaleString()}
      className={cn('text-sm text-[var(--text-secondary,#5A6F77)]', className)}
    >
      {display}
    </time>
  );
}

// ── Duration component ───────────────────────────────────────────────────────

interface DurationProps {
  /** ISO 8601 start timestamp */
  startedAt: string;
  /** ISO 8601 end timestamp (if null, uses current time — live duration) */
  endedAt?: string | null;
  className?: string;
}

export function Duration({ startedAt, endedAt, className }: DurationProps) {
  const startMs = new Date(startedAt).getTime();
  const [display, setDisplay] = useState(() =>
    formatDuration(startMs, endedAt ? new Date(endedAt).getTime() : Date.now()),
  );

  useEffect(() => {
    // Only tick if session is still active (no endedAt)
    if (endedAt) {
      setDisplay(formatDuration(startMs, new Date(endedAt).getTime()));
      return;
    }

    const interval = setInterval(
      () => setDisplay(formatDuration(startMs, Date.now())),
      30_000,
    );
    return () => clearInterval(interval);
  }, [startedAt, endedAt]);

  return (
    <span className={cn('text-sm text-[var(--text-secondary,#5A6F77)]', className)}>
      {display}
    </span>
  );
}
