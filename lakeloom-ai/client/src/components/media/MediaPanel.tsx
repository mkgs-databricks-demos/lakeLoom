import { AudioPlayer } from './AudioPlayer';
import { DocumentViewer } from './DocumentViewer';
import { ImageViewer } from './ImageViewer';

export interface UploadItem {
  id: string;
  kind: string;
  mime_type: string;
  original_filename?: string;
  size_bytes?: number;
  uploaded_at?: string;
  sha256_hex?: string;
}

interface MediaPanelProps {
  upload: UploadItem;
}

/**
 * MediaPanel — renders the appropriate viewer component based on the upload's MIME type.
 * Used in CaptureDetailPage when a user clicks on an upload in the timeline.
 */
export function MediaPanel({ upload }: MediaPanelProps) {
  const { id, kind, mime_type, original_filename, size_bytes, uploaded_at, sha256_hex } = upload;

  // Audio types
  if (mime_type.startsWith('audio/')) {
    return (
      <AudioPlayer
        uploadId={id}
        title={original_filename}
        sizeBytes={size_bytes}
      />
    );
  }

  // Image types
  if (mime_type.startsWith('image/')) {
    return (
      <ImageViewer
        uploadId={id}
        title={original_filename}
        mimeType={mime_type}
        sizeBytes={size_bytes}
        kind={kind === 'photo' ? 'photo' : 'screenshot'}
        uploadedAt={uploaded_at}
      />
    );
  }

  // Document types (PDF, DOCX)
  if (mime_type === 'application/pdf' || mime_type.includes('officedocument')) {
    return (
      <DocumentViewer
        uploadId={id}
        title={original_filename}
        mimeType={mime_type}
        sizeBytes={size_bytes}
        uploadedAt={uploaded_at}
        sha256Hex={sha256_hex}
      />
    );
  }

  // Fallback — unknown type, show download link
  return (
    <div className="bg-[var(--surface-raised)] border border-[var(--border-default)] rounded-xl p-6 text-center">
      <p className="text-sm text-[var(--text-secondary)] mb-2">
        Unsupported file type: {mime_type}
      </p>
      <a
        href={`/api/media/${id}`}
        download={original_filename}
        className="text-sm text-[var(--accent-info)] hover:underline"
      >
        Download file
      </a>
    </div>
  );
}
