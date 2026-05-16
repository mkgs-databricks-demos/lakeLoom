/**
 * ConfirmDialog — destructive action confirmation modal.
 *
 * Brand spec: Modal pattern with --surface-raised bg, rounded-xl,
 * shadow-xl, scale-up entrance (300ms ease-out), focus trapped inside.
 * Uses danger variant button for destructive confirm action.
 */

import { useEffect, useRef } from 'react';
import { cn } from '../lib/utils';
import { AlertTriangle, X } from 'lucide-react';

interface ConfirmDialogProps {
  /** Whether the dialog is open */
  open: boolean;
  /** Called when dialog should close (cancel or backdrop click) */
  onClose: () => void;
  /** Called when the user confirms the action */
  onConfirm: () => void;
  /** Dialog title */
  title: string;
  /** Descriptive message explaining the consequence */
  description: string;
  /** Confirm button text (default: "Confirm") */
  confirmLabel?: string;
  /** Cancel button text (default: "Cancel") */
  cancelLabel?: string;
  /** Whether confirmation is in progress (shows spinner, disables buttons) */
  loading?: boolean;
  /** Visual variant — 'danger' shows red accent, 'default' shows standard */
  variant?: 'danger' | 'default';
}

export function ConfirmDialog({
  open,
  onClose,
  onConfirm,
  title,
  description,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  loading = false,
  variant = 'danger',
}: ConfirmDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    else if (!open && dialog.open) dialog.close();
  }, [open]);

  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && open) onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [open, onClose]);

  const confirmClasses =
    variant === 'danger'
      ? 'bg-[var(--accent-error,#BD2B26)] text-white hover:brightness-90'
      : 'bg-[var(--accent-primary,#FF3621)] text-white hover:brightness-90';

  return (
    <dialog
      ref={dialogRef}
      onClose={onClose}
      onClick={(e) => {
        // Close on backdrop click (click on dialog element itself, not content)
        if (e.target === dialogRef.current) onClose();
      }}
      className={cn(
        'p-0 bg-transparent backdrop:bg-black/40',
        'backdrop:animate-[fadeIn_200ms_ease-out]',
        open && 'open:animate-[scaleIn_300ms_cubic-bezier(0.16,1,0.3,1)]',
      )}
    >
      <div className="bg-[var(--surface-raised,#fff)] border border-[var(--border-default,#DCE0E2)] rounded-xl shadow-xl w-[min(420px,90vw)]">
        {/* Header */}
        <div className="flex items-start gap-3 px-6 py-4 border-b border-[var(--border-default,#DCE0E2)]">
          {variant === 'danger' && (
            <div className="flex-shrink-0 w-10 h-10 rounded-full bg-[var(--accent-error-subtle,#FABFBA)] flex items-center justify-center">
              <AlertTriangle className="w-5 h-5 text-[var(--accent-error,#BD2B26)]" />
            </div>
          )}
          <div className="flex-1">
            <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)]">
              {title}
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] transition-colors duration-100 p-1 rounded-md hover:bg-[var(--surface-tertiary,#EEEDE9)]"
            aria-label="Close"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Body */}
        <div className="px-6 py-4">
          <p className="text-sm text-[var(--text-secondary,#5A6F77)]">
            {description}
          </p>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-3 px-6 py-4 border-t border-[var(--border-default,#DCE0E2)]">
          <button
            type="button"
            onClick={onClose}
            disabled={loading}
            className={cn(
              'px-4 py-2 rounded-lg text-sm font-medium',
              'bg-transparent border border-[var(--border-default,#DCE0E2)] text-[var(--text-primary,#1B3139)]',
              'hover:bg-[var(--surface-tertiary,#EEEDE9)]',
              'transition-colors duration-100',
              'disabled:opacity-50 disabled:cursor-not-allowed',
            )}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={loading}
            className={cn(
              'px-4 py-2 rounded-lg text-sm font-medium',
              'transition-colors duration-100',
              'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--border-focus,#2272B4)] focus-visible:ring-offset-2',
              'disabled:opacity-50 disabled:cursor-not-allowed',
              confirmClasses,
            )}
          >
            {loading ? (
              <span className="inline-flex items-center gap-2">
                <span className="w-3.5 h-3.5 border-2 border-current border-t-transparent rounded-full animate-spin" />
                {confirmLabel}
              </span>
            ) : (
              confirmLabel
            )}
          </button>
        </div>
      </div>
    </dialog>
  );
}
