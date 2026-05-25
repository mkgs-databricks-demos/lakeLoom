import { Upload } from 'lucide-react';
import { useCallback, useRef, useState } from 'react';
import { useUpload } from '../hooks/useUpload';
import type { UploadResponse } from '../hooks/useUpload';
import { UploadProgressItem } from './UploadProgressItem';

// ── MIME extension fallback ──────────────────────────────────────────────────

const EXT_TO_MIME: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
};

function resolveMime(file: File): string {
  if (file.type) return file.type;
  const ext = '.' + (file.name.split('.').pop()?.toLowerCase() ?? '');
  return EXT_TO_MIME[ext] ?? '';
}

function formatMimeList(mimes: string[]): string {
  const extMap: Record<string, string> = {
    'image/png': 'PNG',
    'image/jpeg': 'JPEG',
    'application/pdf': 'PDF',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'DOCX',
  };
  return mimes.map((m) => extMap[m] ?? m.split('/')[1]?.toUpperCase() ?? m).join(', ');
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

// ── Types ───────────────────────────────────────────────────────────────────

interface ValidationError {
  id: string;
  filename: string;
  message: string;
}

export interface DragDropZoneProps {
  /** Accepted MIME types (client-side validation + input accept attribute) */
  accept: string[];
  /** Max file size in bytes (default: 5 GB) */
  maxSizeBytes?: number;
  /** Whether multiple files can be dropped (default: true) */
  multiple?: boolean;
  /** Same-origin API endpoint for uploads (e.g. /api/captures/:id/screenshots) */
  uploadUrl: string;
  /** Called per successful upload */
  onUploadComplete?: (response: UploadResponse) => void;
  /** Called when all files in a batch finish */
  onAllComplete?: () => void;
  /** Optional label override */
  label?: string;
  /** Compact mode (reduced height) */
  compact?: boolean;
  /** Max parallel uploads (default: 3) */
  concurrency?: number;
}

// ── Component ───────────────────────────────────────────────────────────────

/**
 * Drag-and-drop file upload zone with file picker fallback, client-side
 * MIME/size validation, and integrated progress items.
 *
 * Brand: Databricks design tokens, DM Sans typography, WCAG AA.
 */
export function DragDropZone({
  accept,
  maxSizeBytes = 5 * 1024 * 1024 * 1024,
  multiple = true,
  uploadUrl,
  onUploadComplete,
  onAllComplete,
  label,
  compact = false,
  concurrency = 3,
}: DragDropZoneProps) {
  const [isDragOver, setIsDragOver] = useState(false);
  const [validationErrors, setValidationErrors] = useState<ValidationError[]>([]);
  const inputRef = useRef<HTMLInputElement>(null);

  const { items, upload, cancel, retry, clearCompleted } = useUpload({
    url: uploadUrl,
    concurrency,
    onSuccess: (response) => onUploadComplete?.(response),
    onAllComplete,
  });

  // ── Validation ──────────────────────────────────────────────────────────

  const validateFiles = useCallback(
    (files: File[]): { valid: File[]; errors: ValidationError[] } => {
      const valid: File[] = [];
      const errors: ValidationError[] = [];

      for (const file of files) {
        const mime = resolveMime(file);

        if (file.size === 0) {
          errors.push({ id: crypto.randomUUID(), filename: file.name, message: 'File is empty' });
        } else if (!mime || !accept.includes(mime)) {
          errors.push({
            id: crypto.randomUUID(),
            filename: file.name,
            message: `File type not supported. Accepted: ${formatMimeList(accept)}`,
          });
        } else if (file.size > maxSizeBytes) {
          errors.push({
            id: crypto.randomUUID(),
            filename: file.name,
            message: `File too large (${formatFileSize(file.size)}). Maximum: ${formatFileSize(maxSizeBytes)}`,
          });
        } else {
          valid.push(file);
        }
      }

      return { valid, errors };
    },
    [accept, maxSizeBytes],
  );

  // ── Handlers ────────────────────────────────────────────────────────────

  const handleFiles = useCallback(
    (fileList: FileList | File[]) => {
      const files = Array.from(fileList);
      const { valid, errors } = validateFiles(files);

      if (errors.length > 0) {
        setValidationErrors((prev) => [...prev, ...errors]);
      }
      if (valid.length > 0) {
        upload(valid);
      }
    },
    [validateFiles, upload],
  );

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragOver(true);
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragOver(false);
  }, []);

  const handleDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      setIsDragOver(false);
      if (e.dataTransfer.files.length > 0) {
        handleFiles(e.dataTransfer.files);
      }
    },
    [handleFiles],
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      if (e.target.files && e.target.files.length > 0) {
        handleFiles(e.target.files);
        // Reset so same file can be re-selected
        e.target.value = '';
      }
    },
    [handleFiles],
  );

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      inputRef.current?.click();
    }
  }, []);

  const dismissError = (id: string) => {
    setValidationErrors((prev) => prev.filter((err) => err.id !== id));
  };

  // ── Derived ─────────────────────────────────────────────────────────────

  const maxSizeLabel = formatFileSize(maxSizeBytes);
  const mimeLabel = formatMimeList(accept);
  const displayLabel = label ?? `Drop ${mimeLabel.toLowerCase()} files here`;
  const hasCompleted = items.some((i) => i.status === 'success');

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div className="space-y-2">
      {/* Drop zone */}
      <div
        role="button"
        tabIndex={0}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
        onClick={() => inputRef.current?.click()}
        onKeyDown={handleKeyDown}
        aria-label={`Upload area. ${displayLabel}`}
        className={`
          relative flex flex-col items-center justify-center gap-1 rounded-xl cursor-pointer
          border-2 border-dashed transition-all duration-[var(--motion-fast,150ms)]
          ${compact ? 'py-4 px-4' : 'py-8 px-6'}
          ${
            isDragOver
              ? 'border-solid border-[var(--accent-primary,#FF3621)] bg-[rgba(255,54,33,0.04)]'
              : 'border-[var(--border-default,#DCE0E2)] hover:border-[var(--border-hover,#A8B4B9)] bg-transparent'
          }
        `}
      >
        <Upload
          className={`
            ${compact ? 'w-5 h-5' : 'w-6 h-6'}
            ${isDragOver ? 'text-[var(--accent-primary,#FF3621)]' : 'text-[var(--text-secondary,#5A6F77)]'}
            transition-colors duration-[var(--motion-fast,150ms)]
          `}
        />
        <p className={`font-medium text-[var(--text-primary,#1B3139)] ${compact ? 'text-sm' : 'text-base'}`}>
          {displayLabel}
        </p>
        <p className={`text-[var(--text-secondary,#5A6F77)] ${compact ? 'text-xs' : 'text-sm'}`}>
          or click to browse &bull; {mimeLabel} up to {maxSizeLabel}
        </p>
      </div>

      {/* Hidden file input */}
      <input
        ref={inputRef}
        type="file"
        className="sr-only"
        accept={accept.join(',')}
        multiple={multiple}
        onChange={handleInputChange}
        tabIndex={-1}
        aria-hidden="true"
      />

      {/* Validation errors */}
      {validationErrors.length > 0 && (
        <div className="space-y-1">
          {validationErrors.map((err) => (
            <div
              key={err.id}
              role="alert"
              className="flex items-center gap-2 px-3 py-1.5 rounded-lg
                         bg-[var(--accent-error-surface,#FEF2F2)] border border-[var(--accent-error,#BD2B26)]/20
                         text-xs text-[var(--accent-error,#BD2B26)]"
            >
              <span className="flex-1 truncate">
                <strong>{err.filename}</strong> — {err.message}
              </span>
              <button
                type="button"
                onClick={() => dismissError(err.id)}
                className="flex-shrink-0 p-0.5 rounded hover:bg-[var(--accent-error,#BD2B26)]/10"
                aria-label={`Dismiss error for ${err.filename}`}
              >
                &times;
              </button>
            </div>
          ))}
        </div>
      )}

      {/* Upload progress items */}
      {items.length > 0 && (
        <div className="space-y-1.5">
          {items.map((item) => (
            <UploadProgressItem
              key={item.id}
              item={item}
              onCancel={cancel}
              onRetry={retry}
            />
          ))}
          {hasCompleted && (
            <button
              type="button"
              onClick={clearCompleted}
              className="text-xs text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)]
                         underline underline-offset-2 transition-colors duration-[var(--motion-fast,150ms)]"
            >
              Clear completed
            </button>
          )}
        </div>
      )}
    </div>
  );
}
