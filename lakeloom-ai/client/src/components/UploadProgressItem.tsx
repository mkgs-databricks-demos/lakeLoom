import { CheckCircle2, AlertCircle, X, RotateCcw, Clock } from 'lucide-react';
import type { UploadItem } from '../hooks/useUpload';

// ── Helpers ─────────────────────────────────────────────────────────────────

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

// ── Component ───────────────────────────────────────────────────────────────

interface UploadProgressItemProps {
  item: UploadItem;
  onCancel: (id: string) => void;
  onRetry: (id: string) => void;
}

/**
 * Displays a single file's upload state: queued, uploading (with progress bar),
 * success, or error (with retry). Follows Databricks brand tokens.
 */
export function UploadProgressItem({ item, onCancel, onRetry }: UploadProgressItemProps) {
  const { id, file, status, progress, error } = item;

  return (
    <div
      className="flex items-center gap-3 px-3 py-2 rounded-lg bg-[var(--surface-secondary,#F8F7F4)]
                 border border-[var(--border-default,#DCE0E2)]"
      role="status"
      aria-live="polite"
      aria-label={`Upload ${file.name}: ${status}`}
    >
      {/* ── Status icon ────────────────────────────────────────────────── */}
      <div className="flex-shrink-0">
        {status === 'queued' && (
          <Clock className="w-4 h-4 text-[var(--text-tertiary,#8C9EA5)]" />
        )}
        {status === 'uploading' && (
          <div className="w-4 h-4 rounded-full border-2 border-[var(--accent-primary,#FF3621)]
                          border-t-transparent animate-spin" />
        )}
        {status === 'success' && (
          <CheckCircle2 className="w-4 h-4 text-[var(--accent-success,#1B8C4E)]" />
        )}
        {status === 'error' && (
          <AlertCircle className="w-4 h-4 text-[var(--accent-error,#BD2B26)]" />
        )}
      </div>

      {/* ── File info + progress ───────────────────────────────────────── */}
      <div className="flex-1 min-w-0">
        <div className="flex items-center justify-between gap-2">
          <span className="text-sm font-medium text-[var(--text-primary,#1B3139)] truncate">
            {file.name}
          </span>
          <span className="text-xs text-[var(--text-tertiary,#8C9EA5)] flex-shrink-0">
            {formatFileSize(file.size)}
          </span>
        </div>

        {/* Progress bar (only while uploading) */}
        {status === 'uploading' && (
          <div className="mt-1.5 h-1 rounded-full bg-[var(--surface-tertiary,#EEEDE9)] overflow-hidden">
            <div
              className="h-full rounded-full bg-[var(--accent-primary,#FF3621)]
                         transition-[width] duration-[var(--motion-fast,150ms)] ease-out"
              style={{ width: `${progress}%` }}
            />
          </div>
        )}

        {/* Queued text */}
        {status === 'queued' && (
          <p className="text-xs text-[var(--text-tertiary,#8C9EA5)] mt-0.5">Waiting…</p>
        )}

        {/* Error message */}
        {status === 'error' && error && (
          <p className="text-xs text-[var(--accent-error,#BD2B26)] mt-0.5" role="alert">
            {error}
          </p>
        )}
      </div>

      {/* ── Action buttons ─────────────────────────────────────────────── */}
      <div className="flex-shrink-0 flex items-center gap-1">
        {(status === 'queued' || status === 'uploading') && (
          <button
            type="button"
            onClick={() => onCancel(id)}
            className="p-1 rounded hover:bg-[var(--surface-tertiary,#EEEDE9)]
                       text-[var(--text-tertiary,#8C9EA5)] hover:text-[var(--text-primary,#1B3139)]
                       transition-colors duration-[var(--motion-fast,150ms)]"
            aria-label={`Cancel upload for ${file.name}`}
          >
            <X className="w-4 h-4" />
          </button>
        )}
        {status === 'error' && (
          <button
            type="button"
            onClick={() => onRetry(id)}
            className="p-1 rounded hover:bg-[var(--surface-tertiary,#EEEDE9)]
                       text-[var(--accent-primary,#FF3621)] hover:text-[var(--accent-primary-hover,#E02E1B)]
                       transition-colors duration-[var(--motion-fast,150ms)]"
            aria-label={`Retry upload for ${file.name}`}
          >
            <RotateCcw className="w-4 h-4" />
          </button>
        )}
      </div>
    </div>
  );
}
