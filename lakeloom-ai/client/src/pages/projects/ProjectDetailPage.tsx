/**
 * ProjectDetailPage — project overview with capture session list.
 *
 * Route: /projects/:id
 * Displays project metadata header + paginated list of capture sessions
 * with state filtering, sort toggle, and browser-side state transitions.
 *
 * Project-level documents open in a modal overlay (same MediaModal used
 * on CaptureDetailPage). PDFs render inline via iframe.
 *
 * The "Pair Device" CTA opens a modal (PairDeviceModal) instead of navigating
 * away, keeping the user in project context.
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate, Link } from 'react-router';
import { ArrowLeft, Smartphone, Loader2, ChevronDown, ArrowUpDown, Mic2, Camera, FileText, Image, FileCode, Trash2 } from 'lucide-react';
import { StatusBadge, TimeAgo, Duration, EmptyState, ConfirmDialog, PairDeviceModal, DragDropZone } from '../../components';
import { MediaModal } from '../../components/media';

// ── Types ──────────────────────────────────────────────────────────────────────

interface Project {
  id?: string;
  project_id?: string;
  project_name?: string;
  name?: string;
  description: string | null;
  created_by_username: string;
  created_at: string;
  updated_at: string;
}

interface CaptureSession {
  id: string;
  project_id: string;
  created_by_user_id: string;
  device_label: string | null;
  state: 'active' | 'completed' | 'cancelled';
  label: string | null;
  started_at: string;
  ended_at: string | null;
  upload_count: number;
  total_size_bytes: number;
  upload_kinds: string[];
}

interface ProjectUpload {
  id: string;
  kind: string;
  mime_type: string;
  original_filename: string | null;
  size_bytes: number;
  uploaded_at: string;
}

interface CapturesResponse {
  captures: CaptureSession[];
}

type StateFilter = 'all' | 'active' | 'completed' | 'cancelled';
type SortDir = 'desc' | 'asc';

// ── Helpers ────────────────────────────────────────────────────────────────────

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const value = bytes / Math.pow(1024, i);
  return `${value.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}
// ── Document type icon resolver ───────────────────────────────────────────────

function getDocumentMeta(mimeType: string): { icon: typeof FileText; color: string; label: string } {
  if (mimeType.startsWith('image/')) {
    return { icon: Image, color: 'text-[var(--accent-info,#2272B4)]', label: 'Image' };
  }
  if (mimeType === 'text/markdown' || mimeType === 'text/x-markdown') {
    return { icon: FileCode, color: 'text-[var(--accent-primary,#FF3621)]', label: 'Markdown' };
  }
  if (mimeType === 'application/pdf') {
    return { icon: FileText, color: 'text-[var(--accent-error,#BD2B26)]', label: 'PDF' };
  }
  // DOCX, PPTX, and other documents
  return { icon: FileText, color: 'text-[var(--accent-warning,#D97706)]', label: 'Document' };
}



// ── Media kind icons ──────────────────────────────────────────────────────────

const KIND_ICON_MAP: Record<string, { icon: typeof Mic2; label: string; color: string }> = {
  audio: { icon: Mic2, label: 'Audio', color: 'text-[var(--accent-primary,#FF3621)]' },
  screenshot: { icon: Camera, label: 'Photo', color: 'text-[var(--accent-info,#2272B4)]' },
  photo: { icon: Camera, label: 'Photo', color: 'text-[var(--accent-info,#2272B4)]' },
  document: { icon: FileText, label: 'Document', color: 'text-[var(--accent-warning,#D97706)]' },
};

function MediaKindIcons({ kinds }: { kinds: string[] }) {
  if (!kinds || kinds.length === 0) return null;

  // Deduplicate photo/screenshot into one icon
  const seen = new Set<string>();
  const normalized: string[] = [];
  for (const k of kinds) {
    const key = k === 'screenshot' ? 'photo' : k;
    if (!seen.has(key)) {
      seen.add(key);
      normalized.push(k);
    }
  }

  return (
    <div className="flex items-center gap-1.5">
      {normalized.map((kind) => {
        const config = KIND_ICON_MAP[kind];
        if (!config) return null;
        const Icon = config.icon;
        return (
          <span
            key={kind}
            title={config.label}
            className={`${config.color} opacity-70`}
          >
            <Icon className="w-3.5 h-3.5" />
          </span>
        );
      })}
    </div>
  );
}

// ── API helpers ────────────────────────────────────────────────────────────────

async function fetchProject(id: string): Promise<Project> {
  const res = await fetch(`/api/v1/projects/${id}`);
  if (!res.ok) throw new Error(`Failed to fetch project: ${res.status}`);
  return res.json();
}

async function fetchCaptures(
  projectId: string,
  state?: StateFilter,
  sort: SortDir = 'desc',
  before?: string | null,
  limit = 25,
): Promise<CapturesResponse> {
  const params = new URLSearchParams();
  if (state && state !== 'all') params.set('state', state);
  if (sort !== 'desc') params.set('sort', sort);
  if (before) params.set('before', before);
  params.set('limit', String(limit));
  const res = await fetch(`/api/projects/${projectId}/captures?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch captures: ${res.status}`);
  return res.json();
}

async function fetchProjectUploads(projectId: string): Promise<ProjectUpload[]> {
  const res = await fetch(`/api/media/project/${projectId}`);
  if (!res.ok) return []; // graceful fallback
  const data = await res.json();
  return data.uploads ?? [];
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

// ── Main component ─────────────────────────────────────────────────────────────

export function ProjectDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [project, setProject] = useState<Project | null>(null);
  const [captures, setCaptures] = useState<CaptureSession[]>([]);
  const [projectUploads, setProjectUploads] = useState<ProjectUpload[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [stateFilter, setStateFilter] = useState<StateFilter>('all');
  const [sortDir, setSortDir] = useState<SortDir>('desc');
  const [hasMore, setHasMore] = useState(false);

  // Confirm dialog state
  const [confirmAction, setConfirmAction] = useState<{
    captureId: string;
    state: 'completed' | 'cancelled';
  } | null>(null);
  const [confirmLoading, setConfirmLoading] = useState(false);

  // Pair device modal state
  const [showPairModal, setShowPairModal] = useState(false);
  const [assignedDevice, setAssignedDevice] = useState<{ id: string; label: string } | null>(null);

  // Document preview modal state
  const [selectedDocument, setSelectedDocument] = useState<ProjectUpload | null>(null);

  const projectId = id!;

  // Delete document handler
  const handleDeleteDocument = async (uploadId: string, filename: string) => {
    if (!window.confirm(`Delete "${filename}"? This cannot be undone.`)) return;
    try {
      const res = await fetch(`/api/media/${uploadId}`, { method: 'DELETE' });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error ?? `Delete failed (${res.status})`);
      }
      // Refresh the list
      fetchProjectUploads(projectId).then(setProjectUploads).catch(() => {});
    } catch (err) {
      setError((err as Error).message);
    }
  };

  // Load project + captures + assigned devices + project-level uploads
  const loadData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [proj, caps, devicesRes, projUploads] = await Promise.all([
        fetchProject(projectId),
        fetchCaptures(projectId, stateFilter, sortDir),
        fetch(`/api/v1/projects/${projectId}/devices`).then(r => r.ok ? r.json() : { devices: [] }),
        fetchProjectUploads(projectId),
      ]);
      setProject(proj);
      setCaptures(caps.captures);
      setHasMore(caps.captures.length >= 25);
      setProjectUploads(projUploads);
      // Set first assigned device (most recent assignment)
      const devices = devicesRes.devices ?? [];
      if (devices.length > 0) {
        setAssignedDevice({ id: devices[0].paired_session_id, label: devices[0].device_label ?? 'iPhone' });
      }
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [projectId, stateFilter, sortDir]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Load more (cursor-based via ?before=)
  const loadMore = async () => {
    if (loadingMore || captures.length === 0) return;
    const lastCapture = captures[captures.length - 1];
    try {
      setLoadingMore(true);
      const data = await fetchCaptures(projectId, stateFilter, sortDir, lastCapture.started_at);
      setCaptures((prev) => [...prev, ...data.captures]);
      setHasMore(data.captures.length >= 25);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoadingMore(false);
    }
  };

  // State transition handler
  const handleTransition = async () => {
    if (!confirmAction) return;
    try {
      setConfirmLoading(true);
      await transitionCaptureState(confirmAction.captureId, confirmAction.state);
      setConfirmAction(null);
      loadData(); // Refresh the list
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setConfirmLoading(false);
    }
  };

  // Device selected handler (from modal) — associates device with project
  const handleDeviceSelected = async (deviceId: string, deviceLabel: string) => {
    try {
      const res = await fetch(`/api/v1/projects/${projectId}/devices`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ paired_session_id: deviceId }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.detail || `Failed to assign device: ${res.status}`);
      }
      setAssignedDevice({ id: deviceId, label: deviceLabel });
    } catch (err) {
      setError((err as Error).message);
    }
  };

  const projectName = project?.project_name ?? project?.name ?? 'Project';

  // ── Render ─────────────────────────────────────────────────────────────────────

  return (
    <div className="max-w-7xl mx-auto px-6 py-6">
      {/* ── Back nav ──────────────────────────────────────────────────────────── */}
      <Link
        to="/"
        className="inline-flex items-center gap-1.5 text-sm text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] transition-colors duration-100 mb-4"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to Projects
      </Link>

      {/* ── Project header ────────────────────────────────────────────────────── */}
      {project && (
        <div className="mb-8">
          <h1 className="text-2xl font-bold text-[var(--text-primary,#1B3139)]">
            {projectName}
          </h1>
          {project.description && (
            <p className="text-sm text-[var(--text-secondary,#5A6F77)] mt-1">
              {project.description}
            </p>
          )}
          <div className="flex items-center gap-4 mt-2 text-xs text-[var(--text-secondary,#5A6F77)]">
            <span>Created by {project.created_by_username}</span>
            <span>·</span>
            <TimeAgo date={project.updated_at} className="text-xs" />
          </div>
        </div>
      )}

      {/* ── Project-level documents ──────────────────────────────────────────── */}
      <div className="mb-8">
        <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)] mb-3">
          Project Documents
        </h2>
        {projectUploads.length > 0 && (
          <div className="grid gap-2 mb-4">
            {projectUploads.map((upload) => (
              <div
                key={upload.id}
                className="flex items-center gap-3 px-4 py-3 rounded-lg border
                           border-[var(--border-default,#DCE0E2)] bg-[var(--surface-raised,#fff)]
                           hover:border-[var(--border-focus,#2272B4)] hover:shadow-sm
                           transition-all duration-200 group cursor-pointer"
              >
                <div className="flex-1 flex items-center gap-3 min-w-0" onClick={() => setSelectedDocument(upload)}>
                  {(() => { const meta = getDocumentMeta(upload.mime_type); const Icon = meta.icon; return <Icon className={`w-5 h-5 ${meta.color} shrink-0`} />; })()}
                  <div className="flex-1 min-w-0">
                    <span className="text-sm font-medium text-[var(--text-primary,#1B3139)] truncate block">
                      {upload.original_filename ?? getDocumentMeta(upload.mime_type).label}
                    </span>
                    <span className="text-xs text-[var(--text-secondary,#5A6F77)]">
                      {formatBytes(upload.size_bytes)} · {upload.mime_type.split('/').pop()?.toUpperCase()}
                    </span>
                  </div>
                </div>
                <button
                  type="button"
                  onClick={(e) => {
                    e.stopPropagation();
                    handleDeleteDocument(upload.id, upload.original_filename ?? 'Document');
                  }}
                  className="p-1.5 rounded-md opacity-0 group-hover:opacity-100
                             text-[var(--text-tertiary,#8C9EA5)] hover:text-[var(--accent-error,#BD2B26)]
                             hover:bg-[var(--accent-error-subtle,#FABFBA)]
                             transition-all duration-150"
                  aria-label={`Delete ${upload.original_filename ?? 'document'}`}
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>
        )}

        {/* Browser document upload zone */}
        <DragDropZone
          accept={[
            'application/pdf',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'text/markdown',
            'image/png',
            'image/jpeg',
          ]}
          maxSizeBytes={5 * 1024 * 1024 * 1024}
          multiple
          compact
          concurrency={3}
          uploadUrl={`/api/projects/${projectId}/documents`}
          onUploadComplete={() => {
            // Refresh documents after successful upload
            fetchProjectUploads(projectId).then(setProjectUploads).catch(() => {});
          }}
          label="Drop documents, images, or markdown here"
        />
      </div>

      {/* ── Section header + filter + sort ───────────────────────────────────── */}
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-3">
          <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)]">
            Capture Sessions
          </h2>
          {assignedDevice && (
            <button
              type="button"
              onClick={() => setShowPairModal(true)}
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium
                         bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]
                         border border-[var(--accent-success,#00A972)]/20
                         hover:brightness-95 transition-colors duration-100 cursor-pointer"
            >
              <Smartphone className="w-3 h-3" />
              {assignedDevice.label}
            </button>
          )}
          {!assignedDevice && !loading && (
            <button
              type="button"
              onClick={() => setShowPairModal(true)}
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium
                         bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-secondary,#5A6F77)]
                         border border-[var(--border-default,#DCE0E2)]
                         hover:border-[var(--border-focus,#2272B4)] transition-colors duration-100 cursor-pointer"
            >
              <Smartphone className="w-3 h-3" />
              Connect device
            </button>
          )}
        </div>
        <div className="flex items-center gap-2">
          {/* Sort toggle */}
          <button
            type="button"
            onClick={() => setSortDir((prev) => (prev === 'desc' ? 'asc' : 'desc'))}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border text-sm
                       bg-[var(--surface-raised,#fff)] border-[var(--border-default,#DCE0E2)]
                       text-[var(--text-primary,#1B3139)]
                       hover:bg-[var(--surface-tertiary,#EEEDE9)]
                       transition-colors duration-100 cursor-pointer"
            aria-label={`Sort by date ${sortDir === 'desc' ? 'ascending' : 'descending'}`}
          >
            <ArrowUpDown className="w-3.5 h-3.5" />
            <span className="text-xs">{sortDir === 'desc' ? 'Newest' : 'Oldest'}</span>
          </button>
          {/* State filter */}
          <div className="relative">
            <select
              value={stateFilter}
              onChange={(e) => setStateFilter(e.target.value as StateFilter)}
              className="appearance-none pl-3 pr-8 py-1.5 rounded-lg border text-sm
                         bg-[var(--surface-raised,#fff)] border-[var(--border-default,#DCE0E2)]
                         text-[var(--text-primary,#1B3139)]
                         focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                         transition-shadow duration-100 cursor-pointer"
            >
              <option value="all">All states</option>
              <option value="active">Active</option>
              <option value="completed">Completed</option>
              <option value="cancelled">Cancelled</option>
            </select>
            <ChevronDown className="absolute right-2 top-1/2 -translate-y-1/2 w-4 h-4 text-[var(--text-secondary,#5A6F77)] pointer-events-none" />
          </div>
        </div>
      </div>

      {/* ── Error state ───────────────────────────────────────────────────────── */}
      {error && (
        <div className="mb-4 px-4 py-3 rounded-lg border-l-[3px] border-l-[var(--accent-error,#BD2B26)]
                        bg-[var(--accent-error-subtle,#FABFBA)] text-sm text-[var(--text-primary,#1B3139)]">
          {error}
        </div>
      )}

      {/* ── Loading skeleton ──────────────────────────────────────────────────── */}
      {loading && (
        <div className="space-y-3">
          {[1, 2, 3].map((i) => (
            <div
              key={i}
              className="rounded-xl border border-[var(--border-default,#DCE0E2)] bg-[var(--surface-raised,#fff)] p-5 animate-pulse"
            >
              <div className="h-4 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-1/3 mb-3" />
              <div className="h-3 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-2/3" />
            </div>
          ))}
        </div>
      )}

      {/* ── Empty state ───────────────────────────────────────────────────────── */}
      {!loading && captures.length === 0 && (
        <EmptyState
          icon={<Smartphone className="w-7 h-7" />}
          title="No capture sessions yet"
          description="Pair a device to start capturing audio, screenshots, and documents for this project."
          action={
            <button
              type="button"
              onClick={() => setShowPairModal(true)}
              className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                         bg-[var(--accent-primary,#FF3621)] text-white
                         hover:brightness-90 transition-all duration-100"
            >
              Pair Device →
            </button>
          }
        />
      )}

      {/* ── Capture session cards ─────────────────────────────────────────────── */}
      {!loading && captures.length > 0 && (
        <div className="space-y-3">
          {captures.map((capture) => (
            <div
              key={capture.id}
              onClick={() => navigate(`/projects/${projectId}/captures/${capture.id}`)}
              className="group rounded-xl border border-[var(--border-default,#DCE0E2)]
                         bg-[var(--surface-raised,#fff)] p-5
                         cursor-pointer hover:shadow-sm hover:border-[var(--border-focus,#2272B4)]
                         transition-all duration-200"
            >
              <div className="flex items-start justify-between gap-4">
                {/* Left: info */}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <StatusBadge state={capture.state} />
                    {capture.label && (
                      <span className="text-sm font-medium text-[var(--text-primary,#1B3139)] truncate">
                        {capture.label}
                      </span>
                    )}
                    {/* Media type icons */}
                    <MediaKindIcons kinds={capture.upload_kinds} />
                  </div>
                  <div className="flex items-center gap-2 text-xs text-[var(--text-secondary,#5A6F77)]">
                    {capture.device_label && (
                      <>
                        <span>{capture.device_label}</span>
                        <span>·</span>
                      </>
                    )}
                    {capture.state === 'active' ? (
                      <>
                        <span>Started</span>
                        <TimeAgo date={capture.started_at} className="text-xs" />
                      </>
                    ) : (
                      <Duration
                        startedAt={capture.started_at}
                        endedAt={capture.ended_at}
                        className="text-xs"
                      />
                    )}
                    <span>·</span>
                    <span>
                      {capture.upload_count} {capture.upload_count === 1 ? 'file' : 'files'}
                      {capture.total_size_bytes > 0 && ` (${formatBytes(capture.total_size_bytes)})`}
                    </span>
                  </div>
                </div>

                {/* Right: action buttons (active sessions only) */}
                {capture.state === 'active' && (
                  <div
                    className="flex items-center gap-2 opacity-0 group-hover:opacity-100 transition-opacity duration-200"
                    onClick={(e) => e.stopPropagation()}
                  >
                    <button
                      type="button"
                      onClick={() => setConfirmAction({ captureId: capture.id, state: 'completed' })}
                      className="px-3 py-1.5 rounded-lg text-xs font-medium
                                 bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]
                                 hover:brightness-95 transition-colors duration-100"
                    >
                      Complete
                    </button>
                    <button
                      type="button"
                      onClick={() => setConfirmAction({ captureId: capture.id, state: 'cancelled' })}
                      className="px-3 py-1.5 rounded-lg text-xs font-medium
                                 bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-secondary,#5A6F77)]
                                 hover:bg-[var(--accent-error-subtle,#FABFBA)] hover:text-[var(--accent-error,#BD2B26)]
                                 transition-colors duration-100"
                    >
                      Cancel
                    </button>
                  </div>
                )}
              </div>
            </div>
          ))}

          {/* Load more */}
          {hasMore && (
            <div className="flex justify-center pt-2">
              <button
                type="button"
                onClick={loadMore}
                disabled={loadingMore}
                className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                           bg-transparent border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]
                           hover:bg-[var(--surface-tertiary,#EEEDE9)]
                           transition-colors duration-100
                           disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {loadingMore && <Loader2 className="w-4 h-4 animate-spin" />}
                Load more
              </button>
            </div>
          )}
        </div>
      )}

      {/* ── Document preview modal ─────────────────────────────────────────────── */}
      <MediaModal
        upload={selectedDocument}
        onClose={() => setSelectedDocument(null)}
      />

      {/* ── Confirm dialog ────────────────────────────────────────────────────── */}
      <ConfirmDialog
        open={!!confirmAction}
        onClose={() => setConfirmAction(null)}
        onConfirm={handleTransition}
        title={
          confirmAction?.state === 'completed'
            ? 'Mark session as completed?'
            : 'Cancel this capture session?'
        }
        description={
          confirmAction?.state === 'completed'
            ? 'This will mark the capture as complete. No more uploads can be added from the paired device.'
            : 'This will cancel the capture session. No more uploads can be added from the paired device.'
        }
        confirmLabel={confirmAction?.state === 'completed' ? 'Complete' : 'Cancel Session'}
        loading={confirmLoading}
        variant={confirmAction?.state === 'cancelled' ? 'danger' : 'default'}
      />

      {/* ── Pair device modal ──────────────────────────────────────────────────── */}
      <PairDeviceModal
        open={showPairModal}
        onClose={() => setShowPairModal(false)}
        onDeviceSelected={handleDeviceSelected}
        activeDeviceId={assignedDevice?.id ?? null}
      />
    </div>
  );
}
