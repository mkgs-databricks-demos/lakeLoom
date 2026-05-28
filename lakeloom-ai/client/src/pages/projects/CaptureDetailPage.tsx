/**
 * CaptureDetailPage — session detail with upload timeline + transcript.
 *
 * Route: /projects/:id/captures/:cid
 * Displays capture metadata header + chronological upload timeline.
 * State transitions available for active sessions.
 * Inline label editing (click pencil icon to rename).
 * Media preview via modal overlay (click any upload to preview).
 * Audio-transcript sync: inline AudioPlayer feeds currentTimeMs to TranscriptPanel;
 * clicking a transcript segment seeks the audio player.
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { useParams, Link } from 'react-router';
import { ArrowLeft, Clock, Pencil, Check, X } from 'lucide-react';
import { StatusBadge, TimeAgo, Duration, FileIconContainer, EmptyState, ConfirmDialog, DragDropZone } from '../../components';
import { AudioPlayer, MediaModal } from '../../components/media';
import type { AudioPlayerHandle } from '../../components/media';
import { TranscriptPanel } from '../../components/transcript';

// ── Types ────────────────────────────────────────────────────────────────────────────────────

interface Upload {
  id: string;
  kind: string;
  volume_path: string;
  mime_type: string;
  size_bytes: number;
  sha256_hex: string;
  original_filename: string | null;
  client_ts: string | null;
  uploaded_at: string;
}

interface CaptureDetail {
  id: string;
  project_id: string;
  created_by_user_id: string;
  created_by_paired_session_id: string;
  device_label: string | null;
  state: 'active' | 'completed' | 'cancelled';
  label: string | null;
  started_at: string;
  ended_at: string | null;
  uploads?: Upload[];
}

// ── Helpers ───────────────────────────────────────────────────────────────────────────────────

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const value = bytes / Math.pow(1024, i);
  return `${value.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}

function formatTimeOffset(startedAt: string, uploadedAt: string): string {
  const start = new Date(startedAt).getTime();
  const upload = new Date(uploadedAt).getTime();
  const diffMs = upload - start;
  if (diffMs < 60_000) return '+0m';
  const mins = Math.floor(diffMs / 60_000);
  if (mins < 60) return `+${mins}m`;
  const hours = Math.floor(mins / 60);
  const remMins = mins % 60;
  return remMins > 0 ? `+${hours}h${remMins}m` : `+${hours}h`;
}

// ── API helpers ───────────────────────────────────────────────────────────────────────────────

async function fetchCapture(captureId: string): Promise<CaptureDetail> {
  const res = await fetch(`/api/captures/${captureId}?include=uploads`);
  if (!res.ok) throw new Error(`Failed to fetch capture: ${res.status}`);
  return res.json();
}

async function transitionCaptureState(
  captureId: string,
  state: 'completed' | 'cancelled',
): Promise<void> {
  const res = await fetch(`/api/v1/captures/${captureId}/state`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ state }),
  });
  if (!res.ok) throw new Error(`State transition failed: ${res.status}`);
}

async function updateCaptureLabel(
  captureId: string,
  label: string,
): Promise<CaptureDetail> {
  const res = await fetch(`/api/v1/captures/${captureId}/label`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ label }),
  });
  if (!res.ok) throw new Error(`Label update failed: ${res.status}`);
  return res.json();
}

// ── Main component ────────────────────────────────────────────────────────────────────────────

export function CaptureDetailPage() {
  const { id: projectId, cid: captureId } = useParams<{ id: string; cid: string }>();

  const [capture, setCapture] = useState<CaptureDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Confirm dialog state
  const [confirmAction, setConfirmAction] = useState<'completed' | 'cancelled' | null>(null);
  const [confirmLoading, setConfirmLoading] = useState(false);

  // Inline label editing state
  const [isEditingLabel, setIsEditingLabel] = useState(false);
  const [editLabelValue, setEditLabelValue] = useState('');
  const [labelSaving, setLabelSaving] = useState(false);
  const labelInputRef = useRef<HTMLInputElement>(null);

  // Media modal state
  const [selectedUpload, setSelectedUpload] = useState<Upload | null>(null);

  // Audio-transcript sync state
  const [audioTimeMs, setAudioTimeMs] = useState(0);
  const audioPlayerRef = useRef<AudioPlayerHandle>(null);

  useEffect(() => {
    (async () => {
      try {
        setLoading(true);
        setError(null);
        const data = await fetchCapture(captureId!);
        setCapture(data);
      } catch (err) {
        setError((err as Error).message);
      } finally {
        setLoading(false);
      }
    })();
  }, [captureId]);

  const handleTransition = async () => {
    if (!confirmAction || !captureId) return;
    try {
      setConfirmLoading(true);
      await transitionCaptureState(captureId, confirmAction);
      setConfirmAction(null);
      const data = await fetchCapture(captureId);
      setCapture(data);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setConfirmLoading(false);
    }
  };

  // ── Label editing handlers ─────────────────────────────────────────────────────────────────

  const startEditingLabel = () => {
    setEditLabelValue(capture?.label || '');
    setIsEditingLabel(true);
    setTimeout(() => labelInputRef.current?.focus(), 0);
  };

  const cancelEditingLabel = () => {
    setIsEditingLabel(false);
    setEditLabelValue('');
  };

  const saveLabel = async () => {
    const trimmed = editLabelValue.trim();
    if (!trimmed || !captureId) {
      cancelEditingLabel();
      return;
    }
    if (trimmed === (capture?.label || '')) {
      cancelEditingLabel();
      return;
    }
    try {
      setLabelSaving(true);
      const updated = await updateCaptureLabel(captureId, trimmed);
      setCapture((prev) => prev ? { ...prev, label: updated.label } : prev);
      setIsEditingLabel(false);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLabelSaving(false);
    }
  };

  const handleLabelKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      saveLabel();
    } else if (e.key === 'Escape') {
      cancelEditingLabel();
    }
  };

  // ── Audio sync handlers ────────────────────────────────────────────────────────────────────

  const handleAudioTimeUpdate = useCallback((timeMs: number) => {
    setAudioTimeMs(timeMs);
  }, []);

  const handleTranscriptSeek = useCallback((timeMs: number) => {
    audioPlayerRef.current?.seekTo(timeMs);
  }, []);

  const uploads = capture?.uploads ?? [];
  const totalBytes = uploads.reduce((sum, u) => sum + (u.size_bytes || 0), 0);

  // Find primary audio upload for inline player + transcript sync
  const primaryAudio = uploads.find((u) => u.mime_type.startsWith('audio/'));
  // Non-audio uploads for the timeline list
  const nonAudioUploads = uploads.filter((u) => !u.mime_type.startsWith('audio/'));

  // ── Render ───────────────────────────────────────────────────────────────────────────────────

  return (
    <div className="max-w-7xl mx-auto px-6 py-6">
      {/* ── Back nav ──────────────────────────────────────────────────────────────────── */}
      <Link
        to={`/projects/${projectId}`}
        className="inline-flex items-center gap-1.5 text-sm text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] transition-colors duration-100 mb-4"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to project
      </Link>

      {/* ── Error state ───────────────────────────────────────────────────────────────── */}
      {error && (
        <div className="mb-4 px-4 py-3 rounded-lg border-l-[3px] border-l-[var(--accent-error,#BD2B26)]
                        bg-[var(--accent-error-subtle,#FABFBA)] text-sm text-[var(--text-primary,#1B3139)]">
          {error}
        </div>
      )}

      {/* ── Loading skeleton ──────────────────────────────────────────────────────────── */}
      {loading && (
        <div className="space-y-4 animate-pulse">
          <div className="h-6 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-1/3" />
          <div className="h-4 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-2/3" />
          <div className="h-64 bg-[var(--surface-tertiary,#EEEDE9)] rounded-xl mt-6" />
        </div>
      )}

      {/* ── Capture header ────────────────────────────────────────────────────────────── */}
      {!loading && capture && (
        <>
          <div className="mb-6">
            <div className="flex items-center gap-3 mb-2">
              {/* ── Inline label editing ───────────────────── */}
              {isEditingLabel ? (
                <div className="flex items-center gap-2">
                  <input
                    ref={labelInputRef}
                    type="text"
                    value={editLabelValue}
                    onChange={(e) => setEditLabelValue(e.target.value)}
                    onKeyDown={handleLabelKeyDown}
                    onBlur={saveLabel}
                    disabled={labelSaving}
                    maxLength={200}
                    placeholder="Session name..."
                    className="text-xl font-bold text-[var(--text-primary,#1B3139)]
                               bg-[var(--surface-raised,#fff)] border border-[var(--border-focus,#2272B4)]
                               rounded-lg px-3 py-1 min-w-[200px]
                               focus:outline-none focus:ring-2 focus:ring-[var(--border-focus,#2272B4)]
                               disabled:opacity-50"
                  />
                  <button
                    type="button"
                    onClick={saveLabel}
                    disabled={labelSaving}
                    className="p-1.5 rounded-md text-[var(--accent-success,#00A972)]
                               hover:bg-[var(--accent-success-subtle,#dcfce7)] transition-colors duration-100"
                    aria-label="Save label"
                  >
                    <Check className="w-4 h-4" />
                  </button>
                  <button
                    type="button"
                    onClick={cancelEditingLabel}
                    disabled={labelSaving}
                    className="p-1.5 rounded-md text-[var(--text-secondary,#5A6F77)]
                               hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
                    aria-label="Cancel editing"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  onClick={startEditingLabel}
                  className="group inline-flex items-center gap-2 hover:opacity-80 transition-opacity duration-100"
                  aria-label="Edit session label"
                >
                  <h1 className="text-xl font-bold text-[var(--text-primary,#1B3139)]">
                    {capture.label || 'Untitled Capture'}
                  </h1>
                  <Pencil className="w-4 h-4 text-[var(--text-secondary,#5A6F77)] opacity-0 group-hover:opacity-100 transition-opacity duration-200" />
                </button>
              )}
              <StatusBadge state={capture.state} />
            </div>

            {/* Metadata row */}
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-[var(--text-secondary,#5A6F77)]">
              <span>Created by: {capture.created_by_user_id}</span>
              {capture.device_label && <span>Device: {capture.device_label}</span>}
              <span>
                Started: <TimeAgo date={capture.started_at} className="text-xs inline" />
              </span>
              <span>
                Duration: <Duration startedAt={capture.started_at} endedAt={capture.ended_at} className="text-xs inline" />
              </span>
            </div>

            {/* Action buttons for active sessions */}
            {capture.state === 'active' && (
              <div className="flex items-center gap-3 mt-4">
                <button
                  type="button"
                  onClick={() => setConfirmAction('completed')}
                  className="px-4 py-2 rounded-lg text-sm font-medium
                             bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]
                             hover:brightness-95 transition-colors duration-100"
                >
                  Mark Completed
                </button>
                <button
                  type="button"
                  onClick={() => setConfirmAction('cancelled')}
                  className="px-4 py-2 rounded-lg text-sm font-medium
                             bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-secondary,#5A6F77)]
                             hover:bg-[var(--accent-error-subtle,#FABFBA)] hover:text-[var(--accent-error,#BD2B26)]
                             transition-colors duration-100"
                >
                  Cancel Session
                </button>
              </div>
            )}
          </div>

          {/* ── Audio player + transcript (side-by-side on wide screens) ──────────────── */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 border-t border-[var(--border-default,#DCE0E2)] pt-6">
            {/* Left column: Audio + uploads */}
            <div className="space-y-6">
              {/* Inline audio player (primary recording) */}
              {primaryAudio && (
                <AudioPlayer
                  ref={audioPlayerRef}
                  uploadId={primaryAudio.id}
                  title={primaryAudio.original_filename ?? 'Audio recording'}
                  sizeBytes={primaryAudio.size_bytes}
                  onTimeUpdate={handleAudioTimeUpdate}
                />
              )}

              {/* Upload timeline (non-audio files) */}
              <div>
                <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)] mb-4">
                  Uploads
                  {uploads.length > 0 && (
                    <span className="ml-2 text-sm font-normal text-[var(--text-secondary,#5A6F77)]">
                      ({uploads.length} {uploads.length === 1 ? 'file' : 'files'} · {formatBytes(totalBytes)})
                    </span>
                  )}
                </h2>

                {nonAudioUploads.length === 0 && !primaryAudio ? (
                  <EmptyState
                    icon={<Clock className="w-7 h-7" />}
                    title="No uploads yet"
                    description="Files will appear here as they are captured from the paired device."
                  />
                ) : nonAudioUploads.length === 0 ? null : (
                  <div className="space-y-1">
                    {nonAudioUploads.map((upload) => (
                      <div
                        key={upload.id}
                        onClick={() => setSelectedUpload(upload)}
                        className="flex items-center gap-3 px-4 py-3 rounded-lg cursor-pointer
                                   transition-colors duration-100
                                   hover:bg-[var(--surface-tertiary,#EEEDE9)]"
                      >
                        <span className="w-12 text-xs text-[var(--text-secondary,#5A6F77)] font-mono text-right flex-shrink-0">
                          {formatTimeOffset(capture.started_at, upload.uploaded_at)}
                        </span>
                        <FileIconContainer kind={upload.kind} mimeType={upload.mime_type} size={16} />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm text-[var(--text-primary,#1B3139)] truncate">
                            {upload.original_filename || upload.volume_path.split('/').pop() || 'Unknown file'}
                          </p>
                          <p className="text-xs text-[var(--text-secondary,#5A6F77)]">
                            {upload.mime_type}
                          </p>
                        </div>
                        <span className="text-xs text-[var(--text-secondary,#5A6F77)] flex-shrink-0">
                          {formatBytes(upload.size_bytes)}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>

            {/* Right column: Transcript */}
            <div>
              <TranscriptPanel
                captureId={captureId!}
                captureState={capture.state}
                startedAt={capture.started_at}
                currentTimeMs={primaryAudio ? audioTimeMs : undefined}
                onSeek={primaryAudio ? handleTranscriptSeek : undefined}
              />
            </div>
          </div>

          {/* ── Browser upload zone (visible for active/completed sessions) ────────── */}
          {capture.state !== 'cancelled' && (
            <div className="mt-6">
              <DragDropZone
                accept={['image/png', 'image/jpeg']}
                maxSizeBytes={5 * 1024 * 1024 * 1024}
                multiple
                compact
                concurrency={3}
                uploadUrl={`/api/captures/${captureId}/screenshots`}
                onUploadComplete={() => {
                  fetchCapture(captureId!).then(setCapture).catch(() => {});
                }}
              />
            </div>
          )}
        </>
      )}

      {/* ── Media preview modal ────────────────────────────────────────────────────────── */}
      <MediaModal
        upload={selectedUpload}
        onClose={() => setSelectedUpload(null)}
      />

      {/* ── Confirm dialog ────────────────────────────────────────────────────────────── */}
      <ConfirmDialog
        open={!!confirmAction}
        onClose={() => setConfirmAction(null)}
        onConfirm={handleTransition}
        title={
          confirmAction === 'completed'
            ? 'Mark session as completed?'
            : 'Cancel this capture session?'
        }
        description={
          confirmAction === 'completed'
            ? 'This will mark the capture as complete. No more uploads can be added from the paired device.'
            : 'This will cancel the capture session. No more uploads can be added from the paired device.'
        }
        confirmLabel={confirmAction === 'completed' ? 'Complete' : 'Cancel Session'}
        loading={confirmLoading}
        variant={confirmAction === 'cancelled' ? 'danger' : 'default'}
      />
    </div>
  );
}
