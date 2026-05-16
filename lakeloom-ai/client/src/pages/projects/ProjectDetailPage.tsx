/**
 * ProjectDetailPage — project overview with capture session list.
 *
 * Route: /projects/:id
 * Displays project metadata header + paginated list of capture sessions
 * with state filtering and browser-side state transitions.
 *
 * The "Pair iPhone" CTA opens a modal (PairDeviceModal) instead of navigating
 * away, keeping the user in project context.
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useState, useEffect, useCallback } from 'react';
import { useParams, useNavigate, Link } from 'react-router';
import { ArrowLeft, Smartphone, Loader2, ChevronDown } from 'lucide-react';
import { StatusBadge, TimeAgo, Duration, EmptyState, ConfirmDialog, PairDeviceModal } from '../../components';

// ── Types ────────────────────────────────────────────────────────────────────

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
}

interface CapturesResponse {
  captures: CaptureSession[];
}

type StateFilter = 'all' | 'active' | 'completed' | 'cancelled';

// ── Helpers ──────────────────────────────────────────────────────────────────

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const value = bytes / Math.pow(1024, i);
  return `${value.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}

// ── API helpers ──────────────────────────────────────────────────────────────

async function fetchProject(id: string): Promise<Project> {
  const res = await fetch(`/api/v1/projects/${id}`);
  if (!res.ok) throw new Error(`Failed to fetch project: ${res.status}`);
  return res.json();
}

async function fetchCaptures(
  projectId: string,
  state?: StateFilter,
  before?: string | null,
  limit = 25,
): Promise<CapturesResponse> {
  const params = new URLSearchParams();
  if (state && state !== 'all') params.set('state', state);
  if (before) params.set('before', before);
  params.set('limit', String(limit));
  const res = await fetch(`/api/projects/${projectId}/captures?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch captures: ${res.status}`);
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

// ── Main component ───────────────────────────────────────────────────────────

export function ProjectDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [project, setProject] = useState<Project | null>(null);
  const [captures, setCaptures] = useState<CaptureSession[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [stateFilter, setStateFilter] = useState<StateFilter>('all');
  const [hasMore, setHasMore] = useState(false);

  // Confirm dialog state
  const [confirmAction, setConfirmAction] = useState<{
    captureId: string;
    state: 'completed' | 'cancelled';
  } | null>(null);
  const [confirmLoading, setConfirmLoading] = useState(false);

  // Pair device modal state
  const [showPairModal, setShowPairModal] = useState(false);

  const projectId = id!;

  // Load project + captures
  const loadData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [proj, caps] = await Promise.all([
        fetchProject(projectId),
        fetchCaptures(projectId, stateFilter),
      ]);
      setProject(proj);
      setCaptures(caps.captures);
      setHasMore(caps.captures.length >= 25);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [projectId, stateFilter]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Load more (cursor-based via ?before=)
  const loadMore = async () => {
    if (loadingMore || captures.length === 0) return;
    const lastCapture = captures[captures.length - 1];
    try {
      setLoadingMore(true);
      const data = await fetchCaptures(projectId, stateFilter, lastCapture.started_at);
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

  // Device selected handler (from modal)
  const handleDeviceSelected = (deviceId: string, deviceLabel: string) => {
    // For now, just close the modal. In future phases this could
    // trigger a capture session creation on the selected device.
    console.log(`Device selected: ${deviceLabel} (${deviceId})`);
  };

  const projectName = project?.project_name ?? project?.name ?? 'Project';

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className="max-w-7xl mx-auto px-6 py-6">
      {/* ── Back nav ──────────────────────────────────────────────────────── */}
      <Link
        to="/"
        className="inline-flex items-center gap-1.5 text-sm text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] transition-colors duration-100 mb-4"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to Projects
      </Link>

      {/* ── Project header ──────────────────────────────────────────────────── */}
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

      {/* ── Section header + filter ───────────────────────────────────────── */}
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)]">
          Capture Sessions
        </h2>
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

      {/* ── Error state ───────────────────────────────────────────────────── */}
      {error && (
        <div className="mb-4 px-4 py-3 rounded-lg border-l-[3px] border-l-[var(--accent-error,#BD2B26)]
                        bg-[var(--accent-error-subtle,#FABFBA)] text-sm text-[var(--text-primary,#1B3139)]">
          {error}
        </div>
      )}

      {/* ── Loading skeleton ──────────────────────────────────────────────── */}
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

      {/* ── Empty state ───────────────────────────────────────────────────── */}
      {!loading && captures.length === 0 && (
        <EmptyState
          icon={<Smartphone className="w-7 h-7" />}
          title="No capture sessions yet"
          description="Pair an iPhone to start capturing audio, screenshots, and documents for this project."
          action={
            <button
              type="button"
              onClick={() => setShowPairModal(true)}
              className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                         bg-[var(--accent-primary,#FF3621)] text-white
                         hover:brightness-90 transition-all duration-100"
            >
              Pair iPhone →
            </button>
          }
        />
      )}

      {/* ── Capture session cards ─────────────────────────────────────────── */}
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

      {/* ── Confirm dialog ────────────────────────────────────────────────── */}
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

      {/* ── Pair device modal ──────────────────────────────────────────────── */}
      <PairDeviceModal
        open={showPairModal}
        onClose={() => setShowPairModal(false)}
        onDeviceSelected={handleDeviceSelected}
      />
    </div>
  );
}
