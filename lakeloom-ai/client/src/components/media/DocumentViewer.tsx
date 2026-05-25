import { Download, ExternalLink, FileText } from 'lucide-react';
import { MarkdownDocument } from '../MarkdownDocument';

interface DocumentViewerProps {
  /** Upload ID — used to build the stream URL */
  uploadId: string;
  /** Display title */
  title?: string;
  /** MIME type */
  mimeType?: string;
  /** File size in bytes */
  sizeBytes?: number;
  /** Upload timestamp */
  uploadedAt?: string;
  /** SHA-256 hex hash */
  sha256Hex?: string;
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function getDocumentTypeLabel(mimeType?: string): string {
  switch (mimeType) {
    case 'application/pdf': return 'PDF Document';
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document': return 'Word Document';
    case 'application/vnd.openxmlformats-officedocument.presentationml.presentation': return 'PowerPoint';
    case 'text/markdown': return 'Markdown';
    case 'image/png': return 'PNG Image';
    case 'image/jpeg': return 'JPEG Image';
    default: return 'Document';
  }
}

function getFileExtension(mimeType?: string): string {
  switch (mimeType) {
    case 'application/pdf': return '.pdf';
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document': return '.docx';
    case 'application/vnd.openxmlformats-officedocument.presentationml.presentation': return '.pptx';
    case 'text/markdown': return '.md';
    case 'image/png': return '.png';
    case 'image/jpeg': return '.jpg';
    default: return '';
  }
}

export function DocumentViewer({ uploadId, title, mimeType, sizeBytes, uploadedAt, sha256Hex }: DocumentViewerProps) {
  const streamUrl = `/api/media/${uploadId}`;
  const isPdf = mimeType === 'application/pdf';
  const isMarkdown = mimeType === 'text/markdown';
  const isImage = mimeType?.startsWith('image/');
  const typeLabel = getDocumentTypeLabel(mimeType);
  const ext = getFileExtension(mimeType);

  return (
    <div className="bg-[var(--surface-raised)] border border-[var(--border-default)] rounded-xl overflow-hidden">
      {/* PDF inline viewer */}
      {isPdf && (
        <div className="relative w-full h-[500px] bg-[var(--surface-secondary)]">
          <iframe
            src={`${streamUrl}#toolbar=1&navpanes=0`}
            className="absolute inset-0 w-full h-full border-none"
            title={title ?? 'PDF Document'}
          />
        </div>
      )}

      {/* Markdown viewer/editor */}
      {isMarkdown && (
        <MarkdownDocument
          uploadId={uploadId}
          filename={title ?? 'document.md'}
        />
      )}

      {/* Image inline viewer */}
      {isImage && (
        <div className="flex items-center justify-center p-4 bg-[var(--surface-secondary)]">
          <img
            src={streamUrl}
            alt={title ?? 'Image'}
            className="max-w-full max-h-[500px] rounded-lg object-contain"
          />
        </div>
      )}

      {/* Fallback for non-viewable types (DOCX, PPTX etc.) — download card */}
      {!isPdf && !isMarkdown && !isImage && (
        <div className="flex flex-col items-center justify-center py-12 px-6">
          <div className="w-16 h-16 rounded-2xl bg-[var(--surface-tertiary)] flex items-center justify-center mb-4">
            <FileText className="w-8 h-8 text-[var(--text-secondary)]" />
          </div>
          <h3 className="text-base font-semibold text-[var(--text-primary)] mb-1">
            {title ?? typeLabel}
          </h3>
          <p className="text-sm text-[var(--text-secondary)] mb-4">
            {typeLabel} — download to view
          </p>
          <a
            href={streamUrl}
            download={title ? `${title}${ext}` : `document${ext}`}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-[var(--accent-primary)] text-white text-sm font-medium hover:brightness-90 transition-all duration-[var(--motion-fast)]"
          >
            <Download className="w-4 h-4" />
            Download
          </a>
        </div>
      )}

      {/* Info footer */}
      <div className="px-4 py-3 border-t border-[var(--border-default)] flex items-center justify-between">
        <div className="flex items-center gap-3">
          <FileText className="w-4 h-4 text-[var(--text-tertiary)]" />
          <div className="flex flex-col">
            <span className="text-xs font-medium text-[var(--text-primary)] truncate max-w-[200px]">
              {title ?? typeLabel}
            </span>
            <span className="text-xs text-[var(--text-tertiary)]">
              {typeLabel}
              {sizeBytes ? ` • ${formatFileSize(sizeBytes)}` : ''}
              {uploadedAt ? ` • ${new Date(uploadedAt).toLocaleDateString()}` : ''}
            </span>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isPdf && (
            <a
              href={streamUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="w-8 h-8 flex items-center justify-center rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)]"
              title="Open in new tab"
            >
              <ExternalLink className="w-4 h-4" />
            </a>
          )}
          <a
            href={streamUrl}
            download={title ?? `document${ext}`}
            className="w-8 h-8 flex items-center justify-center rounded-md text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-tertiary)] transition-colors duration-[var(--motion-fast)]"
            title="Download"
          >
            <Download className="w-4 h-4" />
          </a>
        </div>
      </div>

      {/* SHA-256 (collapsible detail) */}
      {sha256Hex && (
        <div className="px-4 pb-3">
          <details className="group">
            <summary className="text-xs text-[var(--text-tertiary)] cursor-pointer hover:text-[var(--text-secondary)] transition-colors">
              Integrity hash
            </summary>
            <code className="block mt-1 text-xs font-mono text-[var(--text-tertiary)] break-all bg-[var(--surface-secondary)] rounded px-2 py-1">
              SHA-256: {sha256Hex}
            </code>
          </details>
        </div>
      )}
    </div>
  );
}
