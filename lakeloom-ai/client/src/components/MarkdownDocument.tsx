import { Pencil, Check, X, Loader2 } from 'lucide-react';
import { useCallback, useEffect, useRef, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

// ── Types ───────────────────────────────────────────────────────────────────

interface MarkdownDocumentProps {
  /** Upload ID used for fetching content and saving edits */
  uploadId: string;
  /** Original filename (for display) */
  filename: string;
  /** Called after a successful save */
  onSaved?: () => void;
}

// ── Component ───────────────────────────────────────────────────────────────

/**
 * Displays a markdown document with rendered output by default.
 * Provides an edit button that switches to a textarea editor.
 * Saves edits back to the server via PUT /api/media/:id/content.
 *
 * Brand: Databricks semantic tokens, DM Sans prose styling.
 */
export function MarkdownDocument({ uploadId, filename, onSaved }: MarkdownDocumentProps) {
  const [content, setContent] = useState<string>('');
  const [editContent, setEditContent] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isEditing, setIsEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // ── Fetch content ─────────────────────────────────────────────────────

  const fetchContent = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const res = await fetch(`/api/media/${uploadId}`);
      if (!res.ok) throw new Error(`Failed to load (${res.status})`);
      const text = await res.text();
      setContent(text);
      setEditContent(text);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [uploadId]);

  useEffect(() => {
    fetchContent();
  }, [fetchContent]);

  // ── Edit handlers ─────────────────────────────────────────────────────

  const startEditing = () => {
    setEditContent(content);
    setIsEditing(true);
    setTimeout(() => textareaRef.current?.focus(), 0);
  };

  const cancelEditing = () => {
    setIsEditing(false);
    setEditContent(content);
  };

  const saveEdits = async () => {
    try {
      setSaving(true);
      const res = await fetch(`/api/media/${uploadId}/content`, {
        method: 'PUT',
        headers: { 'Content-Type': 'text/markdown' },
        body: editContent,
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error ?? `Save failed (${res.status})`);
      }
      setContent(editContent);
      setIsEditing(false);
      onSaved?.();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setSaving(false);
    }
  };

  // ── Loading state ─────────────────────────────────────────────────────

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12">
        <Loader2 className="w-5 h-5 text-[var(--text-secondary,#5A6F77)] animate-spin" />
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

  // ── Render ────────────────────────────────────────────────────────────

  return (
    <div className="rounded-xl border border-[var(--border-default,#DCE0E2)] overflow-hidden">
      {/* Header bar */}
      <div className="flex items-center justify-between px-4 py-2
                      bg-[var(--surface-secondary,#F8F7F4)] border-b border-[var(--border-default,#DCE0E2)]">
        <span className="text-sm font-medium text-[var(--text-primary,#1B3139)] truncate">
          {filename}
        </span>
        <div className="flex items-center gap-1">
          {isEditing ? (
            <>
              <button
                type="button"
                onClick={saveEdits}
                disabled={saving}
                className="inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium
                           bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]
                           hover:brightness-95 transition-colors duration-100 disabled:opacity-50"
              >
                {saving ? <Loader2 className="w-3 h-3 animate-spin" /> : <Check className="w-3 h-3" />}
                Save
              </button>
              <button
                type="button"
                onClick={cancelEditing}
                disabled={saving}
                className="inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium
                           text-[var(--text-secondary,#5A6F77)] hover:bg-[var(--surface-tertiary,#EEEDE9)]
                           transition-colors duration-100 disabled:opacity-50"
              >
                <X className="w-3 h-3" />
                Cancel
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={startEditing}
              className="inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium
                         text-[var(--text-secondary,#5A6F77)] hover:bg-[var(--surface-tertiary,#EEEDE9)]
                         transition-colors duration-100"
            >
              <Pencil className="w-3 h-3" />
              Edit
            </button>
          )}
        </div>
      </div>

      {/* Content area */}
      {isEditing ? (
        <textarea
          ref={textareaRef}
          value={editContent}
          onChange={(e) => setEditContent(e.target.value)}
          disabled={saving}
          className="w-full min-h-[300px] p-4 font-mono text-sm
                     text-[var(--text-primary,#1B3139)] bg-[var(--surface-raised,#fff)]
                     border-none outline-none resize-y disabled:opacity-50"
          placeholder="Write markdown here..."
        />
      ) : (
        <div className="p-4 prose prose-sm max-w-none
                        prose-headings:text-[var(--text-primary,#1B3139)]
                        prose-p:text-[var(--text-primary,#1B3139)]
                        prose-a:text-[var(--accent-info,#2272B4)]
                        prose-strong:text-[var(--text-primary,#1B3139)]
                        prose-code:text-[var(--accent-primary,#FF3621)]
                        prose-code:bg-[var(--surface-tertiary,#EEEDE9)]
                        prose-code:px-1 prose-code:py-0.5 prose-code:rounded
                        prose-pre:bg-[var(--surface-tertiary,#EEEDE9)]
                        prose-pre:text-[var(--text-primary,#1B3139)]
                        prose-li:text-[var(--text-primary,#1B3139)]">
          {content ? (
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
          ) : (
            <p className="text-[var(--text-tertiary,#8C9EA5)] italic">Empty document</p>
          )}
        </div>
      )}
    </div>
  );
}
