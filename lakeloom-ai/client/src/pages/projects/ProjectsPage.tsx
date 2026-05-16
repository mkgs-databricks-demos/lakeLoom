/**
 * ProjectsPage — lakeLoom project management UI.
 *
 * Databricks brand: DM Sans, semantic tokens, Lava 600 accents,
 * Navy 800 text on light surfaces, full dark/light mode support.
 *
 * Pagination: Cursor-based. Server returns `next_cursor` + `has_more`.
 * Client appends pages via "Load more" button (no infinite scroll — intentional
 * so the user doesn't lose their scroll position on archive/restore actions).
 */

import { useState, useEffect, useCallback, useRef, type FormEvent } from 'react';
import { useNavigate } from 'react-router';
import { Plus, Search, Archive, RotateCcw, Pencil, FolderOpen, Loader2, Smartphone } from 'lucide-react';

// ── Types ────────────────────────────────────────────────────────────────────

interface Project {
  project_id: string;
  project_name: string;
  description: string | null;
  workspace_id: string;
  created_by_user_id: string;
  created_by_username: string;
  created_at: string;
  updated_at: string;
  archived: boolean;
}

interface ProjectsResponse {
  projects: Project[];
  next_cursor: string | null;
  has_more: boolean;
}

// ── API helpers ──────────────────────────────────────────────────────────────

async function fetchProjects(
  showArchived: boolean,
  search?: string,
  cursor?: string | null,
  limit = 25,
): Promise<ProjectsResponse> {
  const params = new URLSearchParams();
  if (showArchived) params.set('archived', 'true');
  if (search) params.set('q', search);
  if (cursor) params.set('cursor', cursor);
  params.set('limit', String(limit));
  const res = await fetch(`/api/v1/projects?${params}`);
  if (!res.ok) throw new Error(`Failed to fetch projects: ${res.status}`);
  return res.json();
}

async function createProject(name: string, description?: string): Promise<Project> {
  const res = await fetch('/api/v1/projects', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, description: description || null, workspace_id: '' }),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.detail || `Create failed: ${res.status}`);
  }
  return res.json();
}

async function updateProject(id: string, data: { name?: string; description?: string | null }): Promise<Project> {
  const res = await fetch(`/api/v1/projects/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  if (!res.ok) throw new Error(`Update failed: ${res.status}`);
  return res.json();
}

async function archiveProject(id: string): Promise<void> {
  const res = await fetch(`/api/v1/projects/${id}/archive`, { method: 'PATCH' });
  if (!res.ok) throw new Error(`Archive failed: ${res.status}`);
}

async function restoreProject(id: string): Promise<void> {
  const res = await fetch(`/api/v1/projects/${id}/restore`, { method: 'PATCH' });
  if (!res.ok) throw new Error(`Restore failed: ${res.status}`);
}

// ── Main component ───────────────────────────────────────────────────────────

export function ProjectsPage() {
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [search, setSearch] = useState('');
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [editingProject, setEditingProject] = useState<Project | null>(null);
  const navigate = useNavigate();

  // Device assignments per project (project_id → device label)
  const [projectDevices, setProjectDevices] = useState<Record<string, string>>({});

  // Fetch devices for loaded projects
  const fetchProjectDevices = async (projectIds: string[]) => {
    const results: Record<string, string> = {};
    await Promise.all(
      projectIds.map(async (pid) => {
        try {
          const res = await fetch(`/api/v1/projects/${pid}/devices`);
          if (res.ok) {
            const data = await res.json();
            const devices = data.devices ?? [];
            if (devices.length > 0) {
              results[pid] = devices[0].device_label ?? 'Device';
            }
          }
        } catch { /* ignore */ }
      })
    );
    setProjectDevices((prev) => ({ ...prev, ...results }));
  };

  // Debounce search input to avoid hammering the API
  const searchTimeout = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [debouncedSearch, setDebouncedSearch] = useState('');

  useEffect(() => {
    clearTimeout(searchTimeout.current);
    searchTimeout.current = setTimeout(() => setDebouncedSearch(search), 300);
    return () => clearTimeout(searchTimeout.current);
  }, [search]);

  // Load first page (resets on filter/search change)
  const loadProjects = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await fetchProjects(showArchived, debouncedSearch || undefined, null);
      setProjects(data.projects);
      setNextCursor(data.next_cursor);
      setHasMore(data.has_more);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [showArchived, debouncedSearch]);

  useEffect(() => {
    loadProjects();
  }, [loadProjects]);

  // Fetch device assignments whenever projects change
  useEffect(() => {
    if (projects.length > 0) {
      fetchProjectDevices(projects.map((p) => p.project_id));
    }
  }, [projects]);

  // Load next page (appends to existing results)
  const loadMore = async () => {
    if (!nextCursor || loadingMore) return;
    try {
      setLoadingMore(true);
      const data = await fetchProjects(showArchived, debouncedSearch || undefined, nextCursor);
      setProjects((prev) => [...prev, ...data.projects]);
      setNextCursor(data.next_cursor);
      setHasMore(data.has_more);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoadingMore(false);
    }
  };

  const handleArchive = async (id: string) => {
    await archiveProject(id);
    loadProjects(); // Reset to first page to avoid stale cursor state
  };

  const handleRestore = async (id: string) => {
    await restoreProject(id);
    loadProjects();
  };

  return (
    <div className="max-w-7xl mx-auto px-6 py-6">
      {/* ── Header ─────────────────────────────────────────────────────── */}
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-[var(--text-primary,#1B3139)]">
            Projects
          </h1>
          <p className="text-sm text-[var(--text-secondary,#5A6F77)] mt-1">
            Manage your lakeLoom capture projects
          </p>
        </div>
        <button
          onClick={() => setShowCreateModal(true)}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                     bg-[var(--accent-primary,#FF3621)] text-white
                     hover:brightness-90 transition-all duration-100
                     focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--border-focus,#2272B4)] focus-visible:ring-offset-2"
        >
          <Plus className="w-4 h-4" />
          New Project
        </button>
      </div>

      {/* ── Search & Filter Bar ────────────────────────────────────────── */}
      <div className="flex items-center gap-3 mb-6">
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-[var(--text-tertiary,#618794)]" />
          <input
            type="text"
            placeholder="Search projects..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full pl-9 pr-3 py-2 rounded-lg border text-sm
                       bg-[var(--surface-raised,#fff)] border-[var(--border-default,#DCE0E2)]
                       text-[var(--text-primary,#1B3139)] placeholder:text-[var(--text-tertiary,#618794)]
                       focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                       transition-shadow duration-100"
          />
        </div>
        <label className="inline-flex items-center gap-2 text-sm text-[var(--text-secondary,#5A6F77)] cursor-pointer select-none">
          <input
            type="checkbox"
            checked={showArchived}
            onChange={(e) => setShowArchived(e.target.checked)}
            className="rounded border-[var(--border-default,#DCE0E2)]"
          />
          Show archived
        </label>
      </div>

      {/* ── Error state ────────────────────────────────────────────────── */}
      {error && (
        <div className="mb-4 px-4 py-3 rounded-lg border-l-[3px] border-l-[var(--accent-error,#BD2B26)]
                        bg-[var(--accent-error-subtle,#FABFBA)] text-sm text-[var(--text-primary,#1B3139)]">
          {error}
        </div>
      )}

      {/* ── Loading state (initial load only) ──────────────────────────── */}
      {loading && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[1, 2, 3].map((i) => (
            <div key={i} className="rounded-xl border border-[var(--border-default,#DCE0E2)]
                                    bg-[var(--surface-raised,#fff)] p-6 animate-pulse">
              <div className="h-5 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-2/3 mb-3" />
              <div className="h-4 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-full mb-2" />
              <div className="h-4 bg-[var(--surface-tertiary,#EEEDE9)] rounded w-1/2" />
            </div>
          ))}
        </div>
      )}

      {/* ── Empty state ────────────────────────────────────────────────── */}
      {!loading && projects.length === 0 && (
        <div className="flex flex-col items-center justify-center py-16 text-center">
          <div className="w-16 h-16 rounded-2xl bg-[var(--surface-tertiary,#EEEDE9)] flex items-center justify-center mb-4">
            <FolderOpen className="w-7 h-7 text-[var(--text-secondary,#5A6F77)]" />
          </div>
          <h3 className="text-lg font-semibold text-[var(--text-primary,#1B3139)] mb-1">
            No projects yet
          </h3>
          <p className="text-sm text-[var(--text-secondary,#5A6F77)] max-w-md mb-6">
            Create your first project to start capturing requirements from your iPhone.
          </p>
          <button
            onClick={() => setShowCreateModal(true)}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                       bg-[var(--accent-primary,#FF3621)] text-white hover:brightness-90
                       transition-all duration-100"
          >
            <Plus className="w-4 h-4" />
            Create Project
          </button>
        </div>
      )}

      {/* ── Project grid ───────────────────────────────────────────────── */}
      {!loading && projects.length > 0 && (
        <>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {projects.map((project) => (
              <ProjectCard
                key={project.project_id}
                project={project}
                deviceLabel={projectDevices[project.project_id] ?? null}
                onClick={() => navigate(`/projects/${project.project_id}`)}
                onEdit={() => setEditingProject(project)}
                onArchive={() => handleArchive(project.project_id)}
                onRestore={() => handleRestore(project.project_id)}
              />
            ))}
          </div>

          {/* ── Load more button ─────────────────────────────────────────── */}
          {hasMore && (
            <div className="flex justify-center mt-6">
              <button
                onClick={loadMore}
                disabled={loadingMore}
                className="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-sm font-medium
                           border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]
                           bg-[var(--surface-raised,#fff)]
                           hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100
                           disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {loadingMore ? (
                  <>
                    <Loader2 className="w-4 h-4 animate-spin" />
                    Loading...
                  </>
                ) : (
                  'Load more projects'
                )}
              </button>
            </div>
          )}
        </>
      )}

      {/* ── Create Modal ───────────────────────────────────────────────── */}
      {showCreateModal && (
        <CreateProjectModal
          onClose={() => setShowCreateModal(false)}
          onCreated={() => { setShowCreateModal(false); loadProjects(); }}
        />
      )}

      {/* ── Edit Modal ─────────────────────────────────────────────────── */}
      {editingProject && (
        <EditProjectModal
          project={editingProject}
          onClose={() => setEditingProject(null)}
          onUpdated={() => { setEditingProject(null); loadProjects(); }}
        />
      )}
    </div>
  );
}

// ── ProjectCard ──────────────────────────────────────────────────────────────

function ProjectCard({
  project,
  deviceLabel,
  onClick,
  onEdit,
  onArchive,
  onRestore,
}: {
  project: Project;
  deviceLabel: string | null;
  onClick: () => void;
  onEdit: () => void;
  onArchive: () => void;
  onRestore: () => void;
}) {
  const timeAgo = formatRelativeTime(project.updated_at);

  return (
    <div
      onClick={onClick}
      className={`rounded-xl border bg-[var(--surface-raised,#fff)] p-6
                     border-[var(--border-default,#DCE0E2)] cursor-pointer
                     hover:shadow-sm hover:border-[var(--border-focus,#2272B4)]
                     transition-all duration-200
                     ${project.archived ? 'opacity-60' : ''}`}>
      <div className="flex items-start justify-between mb-2">
        <h3 className="text-base font-semibold text-[var(--text-primary,#1B3139)] truncate pr-2">
          {project.project_name}
        </h3>
        {project.archived && (
          <span className="shrink-0 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium
                           bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-secondary,#5A6F77)]">
            Archived
          </span>
        )}
      </div>

      {project.description && (
        <p className="text-sm text-[var(--text-secondary,#5A6F77)] line-clamp-2 mb-3">
          {project.description}
        </p>
      )}

      <div className="flex items-center justify-between mb-4">
        <span className="text-xs text-[var(--text-tertiary,#618794)]">
          Updated {timeAgo} · by {project.created_by_username}
        </span>
        {deviceLabel ? (
          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium
                         bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]
                         border border-[var(--accent-success,#00A972)]/20">
            <Smartphone className="w-3 h-3" />
            {deviceLabel}
          </span>
        ) : (
          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium whitespace-nowrap
                         bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-tertiary,#618794)]
                         border border-[var(--border-default,#DCE0E2)]">
            <Smartphone className="w-3 h-3" />
            Unpaired
          </span>
        )}
      </div>

      <div className="flex items-center gap-2" onClick={(e) => e.stopPropagation()}>
        <button
          onClick={onEdit}
          className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium
                     border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]
                     hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
        >
          <Pencil className="w-3.5 h-3.5" />
          Edit
        </button>
        {project.archived ? (
          <button
            onClick={onRestore}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium
                       border border-[var(--border-default,#DCE0E2)] text-[var(--accent-success,#00875C)]
                       hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
          >
            <RotateCcw className="w-3.5 h-3.5" />
            Restore
          </button>
        ) : (
          <button
            onClick={onArchive}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium
                       border border-[var(--border-default,#DCE0E2)] text-[var(--text-secondary,#5A6F77)]
                       hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
          >
            <Archive className="w-3.5 h-3.5" />
            Archive
          </button>
        )}
      </div>
    </div>
  );
}

// ── CreateProjectModal ───────────────────────────────────────────────────────

function CreateProjectModal({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return;

    setSubmitting(true);
    setError(null);
    try {
      await createProject(name.trim(), description.trim() || undefined);
      onCreated();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-[var(--surface-overlay,rgba(27,49,57,0.6))]
                   animate-[fadeIn_200ms_cubic-bezier(0.16,1,0.3,1)]"
        onClick={onClose}
      />
      {/* Dialog */}
      <div className="relative z-41 w-[90vw] max-w-[480px] bg-[var(--surface-raised,#fff)]
                      border border-[var(--border-default,#DCE0E2)] rounded-xl shadow-xl
                      animate-[scaleIn_300ms_cubic-bezier(0.16,1,0.3,1)]">
        <div className="flex items-center justify-between px-6 py-4 border-b border-[var(--border-default,#DCE0E2)]">
          <h2 className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">New Project</h2>
          <button
            onClick={onClose}
            className="text-[var(--text-tertiary,#618794)] hover:text-[var(--text-primary,#1B3139)]
                       transition-colors duration-100 p-1 rounded-md hover:bg-[var(--surface-tertiary,#EEEDE9)]"
          >
            ✕
          </button>
        </div>

        <form onSubmit={handleSubmit} className="px-6 py-4 space-y-4">
          <div className="flex flex-col gap-1.5">
            <label htmlFor="project-name" className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              Name
            </label>
            <input
              id="project-name"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Customer 360 Lakehouse"
              autoFocus
              className="rounded-lg border bg-[var(--surface-raised,#fff)] px-3 py-2 text-sm
                         text-[var(--text-primary,#1B3139)] placeholder:text-[var(--text-tertiary,#618794)]
                         border-[var(--border-default,#DCE0E2)]
                         focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                         transition-shadow duration-100"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="project-desc" className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              Description <span className="text-[var(--text-tertiary,#618794)] font-normal">(optional)</span>
            </label>
            <textarea
              id="project-desc"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Brief description of the project scope..."
              rows={3}
              className="rounded-lg border bg-[var(--surface-raised,#fff)] px-3 py-2 text-sm
                         text-[var(--text-primary,#1B3139)] placeholder:text-[var(--text-tertiary,#618794)]
                         border-[var(--border-default,#DCE0E2)] resize-none
                         focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                         transition-shadow duration-100"
            />
          </div>

          {error && (
            <p className="text-xs text-[var(--accent-error,#BD2B26)]">{error}</p>
          )}

          <div className="flex items-center justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg text-sm font-medium
                         border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]
                         hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!name.trim() || submitting}
              className="px-4 py-2 rounded-lg text-sm font-medium
                         bg-[var(--accent-primary,#FF3621)] text-white
                         hover:brightness-90 transition-all duration-100
                         disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {submitting ? 'Creating...' : 'Create Project'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ── EditProjectModal ─────────────────────────────────────────────────────────

function EditProjectModal({
  project,
  onClose,
  onUpdated,
}: {
  project: Project;
  onClose: () => void;
  onUpdated: () => void;
}) {
  const [name, setName] = useState(project.project_name);
  const [description, setDescription] = useState(project.description || '');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return;

    setSubmitting(true);
    setError(null);
    try {
      await updateProject(project.project_id, {
        name: name.trim(),
        description: description.trim() || null,
      });
      onUpdated();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center">
      <div
        className="absolute inset-0 bg-[var(--surface-overlay,rgba(27,49,57,0.6))]
                   animate-[fadeIn_200ms_cubic-bezier(0.16,1,0.3,1)]"
        onClick={onClose}
      />
      <div className="relative z-41 w-[90vw] max-w-[480px] bg-[var(--surface-raised,#fff)]
                      border border-[var(--border-default,#DCE0E2)] rounded-xl shadow-xl
                      animate-[scaleIn_300ms_cubic-bezier(0.16,1,0.3,1)]">
        <div className="flex items-center justify-between px-6 py-4 border-b border-[var(--border-default,#DCE0E2)]">
          <h2 className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">Edit Project</h2>
          <button
            onClick={onClose}
            className="text-[var(--text-tertiary,#618794)] hover:text-[var(--text-primary,#1B3139)]
                       transition-colors duration-100 p-1 rounded-md hover:bg-[var(--surface-tertiary,#EEEDE9)]"
          >
            ✕
          </button>
        </div>

        <form onSubmit={handleSubmit} className="px-6 py-4 space-y-4">
          <div className="flex flex-col gap-1.5">
            <label htmlFor="edit-name" className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              Name
            </label>
            <input
              id="edit-name"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
              className="rounded-lg border bg-[var(--surface-raised,#fff)] px-3 py-2 text-sm
                         text-[var(--text-primary,#1B3139)]
                         border-[var(--border-default,#DCE0E2)]
                         focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                         transition-shadow duration-100"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="edit-desc" className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              Description
            </label>
            <textarea
              id="edit-desc"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={3}
              className="rounded-lg border bg-[var(--surface-raised,#fff)] px-3 py-2 text-sm
                         text-[var(--text-primary,#1B3139)]
                         border-[var(--border-default,#DCE0E2)] resize-none
                         focus:ring-2 focus:ring-[var(--border-focus,#2272B4)] focus:border-transparent
                         transition-shadow duration-100"
            />
          </div>

          {error && (
            <p className="text-xs text-[var(--accent-error,#BD2B26)]">{error}</p>
          )}

          <div className="flex items-center justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg text-sm font-medium
                         border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]
                         hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!name.trim() || submitting}
              className="px-4 py-2 rounded-lg text-sm font-medium
                         bg-[var(--accent-primary,#FF3621)] text-white
                         hover:brightness-90 transition-all duration-100
                         disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {submitting ? 'Saving...' : 'Save Changes'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function formatRelativeTime(iso: string): string {
  const date = new Date(iso);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const minutes = Math.floor(diff / 60_000);
  const hours = Math.floor(diff / 3_600_000);
  const days = Math.floor(diff / 86_400_000);

  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;
  return date.toLocaleDateString();
}
