/**
 * MediaModal — full-screen modal overlay for previewing media uploads.
 *
 * Uses native <dialog> with hidden open:grid pattern (same as ConfirmDialog)
 * to avoid Tailwind grid overriding UA display:none.
 *
 * Handles: audio, images, documents (PDF inline, DOCX download).
 * Escape key or backdrop click closes. Scale-in entrance animation.
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useEffect, useRef } from 'react';
import { X, Download } from 'lucide-react';
import { MediaPanel, type UploadItem } from './MediaPanel';

interface MediaModalProps {
  /** The upload to preview (null = closed) */
  upload: UploadItem | null;
  /** Called when the modal should close */
  onClose: () => void;
}

export function MediaModal({ upload, onClose }: MediaModalProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (upload && !dialog.open) dialog.showModal();
    else if (!upload && dialog.open) dialog.close();
  }, [upload]);

  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && upload) onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [upload, onClose]);

  const title = upload?.original_filename || 'Media Preview';
  const isAudio = upload?.mime_type.startsWith('audio/');

  return (
    <dialog
      ref={dialogRef}
      onClose={onClose}
      onClick={(e) => {
        // Close on backdrop click (click on dialog element itself, not content)
        if (e.target === dialogRef.current) onClose();
      }}
      className={
        'fixed inset-0 z-50 m-0 p-4 w-screen h-screen max-w-none max-h-none ' +
        'bg-transparent hidden open:grid place-items-center ' +
        'backdrop:bg-black/50'
      }
    >
      <div
        className={
          'bg-[var(--surface-raised,#fff)] border border-[var(--border-default,#DCE0E2)] ' +
          'rounded-xl shadow-xl flex flex-col overflow-hidden ' +
          // Wider for images/docs, narrower for audio
          (isAudio
            ? 'w-[min(520px,calc(100vw-2rem))] max-h-[80vh]'
            : 'w-[min(900px,calc(100vw-2rem))] max-h-[90vh]') +
          (upload ? ' animate-[scaleIn_200ms_cubic-bezier(0.16,1,0.3,1)]' : '')
        }
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-3 border-b border-[var(--border-default,#DCE0E2)] flex-shrink-0">
          <h2 className="text-sm font-semibold text-[var(--text-primary,#1B3139)] truncate pr-4">
            {title}
          </h2>
          <div className="flex items-center gap-1.5">
            {/* Download button */}
            {upload && (
              <a
                href={`/api/media/${upload.id}`}
                download={upload.original_filename ?? 'download'}
                className="w-8 h-8 flex items-center justify-center rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
                title="Download"
              >
                <Download className="w-4 h-4" />
              </a>
            )}
            {/* Close button */}
            <button
              type="button"
              onClick={onClose}
              className="w-8 h-8 flex items-center justify-center rounded-md text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
              aria-label="Close"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>

        {/* Body — media content */}
        <div className="flex-1 overflow-auto p-5">
          {upload && <MediaPanel upload={upload} />}
        </div>

        {/* Footer — file info */}
        {upload && (
          <div className="px-5 py-2.5 border-t border-[var(--border-default,#DCE0E2)] flex items-center gap-4 text-xs text-[var(--text-tertiary,#8C9EA5)] flex-shrink-0">
            <span>{upload.mime_type}</span>
            {upload.size_bytes && (
              <span>{formatBytes(upload.size_bytes)}</span>
            )}
            {upload.uploaded_at && (
              <span>{new Date(upload.uploaded_at).toLocaleString()}</span>
            )}
          </div>
        )}
      </div>
    </dialog>
  );
}

// — Helpers ——————————————————————————————————————————————————————————————————

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const value = bytes / Math.pow(1024, i);
  return `${value.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}
