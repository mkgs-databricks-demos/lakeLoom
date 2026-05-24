import { useCallback, useEffect, useState } from 'react';
import { Camera, Download, Image, Maximize2, X, ZoomIn, ZoomOut } from 'lucide-react';

interface ImageViewerProps {
  /** Upload ID — used to build the image URL */
  uploadId: string;
  /** Display title */
  title?: string;
  /** MIME type (image/jpeg, image/png) */
  mimeType?: string;
  /** File size in bytes */
  sizeBytes?: number;
  /** Kind: screenshot or photo */
  kind?: 'screenshot' | 'photo';
  /** Upload timestamp */
  uploadedAt?: string;
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function ImageViewer({ uploadId, title, mimeType, sizeBytes, kind, uploadedAt }: ImageViewerProps) {
  const [isLightbox, setIsLightbox] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [isLoaded, setIsLoaded] = useState(false);
  const [error, setError] = useState(false);
  const [dimensions, setDimensions] = useState<{ w: number; h: number } | null>(null);

  const imageUrl = `/api/media/${uploadId}`;

  const handleLoad = useCallback((e: React.SyntheticEvent<HTMLImageElement>) => {
    setIsLoaded(true);
    const img = e.currentTarget;
    setDimensions({ w: img.naturalWidth, h: img.naturalHeight });
  }, []);

  const handleError = useCallback(() => {
    setError(true);
    setIsLoaded(true);
  }, []);

  const openLightbox = () => {
    setIsLightbox(true);
    setZoom(1);
  };
  const closeLightbox = () => setIsLightbox(false);

  const zoomIn = () => setZoom((z) => Math.min(z + 0.5, 4));
  const zoomOut = () => setZoom((z) => Math.max(z - 0.5, 0.5));
  const resetZoom = () => setZoom(1);

  // Close on Escape
  useEffect(() => {
    if (!isLightbox) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closeLightbox();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [isLightbox]);

  return (
    <>
      {/* Thumbnail card */}
      <div className="bg-[var(--surface-raised)] border border-[var(--border-default)] rounded-xl overflow-hidden group">
        {/* Image container */}
        <div
          className="relative aspect-video bg-[var(--surface-secondary)] flex items-center justify-center cursor-pointer overflow-hidden"
          onClick={openLightbox}
        >
          {!isLoaded && !error && (
            <div className="absolute inset-0 flex items-center justify-center">
              <div className="w-8 h-8 border-2 border-[var(--border-default)] border-t-[var(--accent-primary)] rounded-full animate-spin" />
            </div>
          )}
          {error ? (
            <div className="flex flex-col items-center gap-2 text-[var(--text-tertiary)]">
              <Image className="w-8 h-8" />
              <span className="text-xs">Failed to load</span>
            </div>
          ) : (
            <img
              src={imageUrl}
              alt={title ?? 'Capture'}
              className="w-full h-full object-contain transition-transform duration-[var(--motion-normal)]"
              onLoad={handleLoad}
              onError={handleError}
              style={{ opacity: isLoaded ? 1 : 0 }}
            />
          )}
          {/* Expand overlay on hover */}
          <div className="absolute inset-0 bg-black/0 group-hover:bg-black/10 transition-colors duration-[var(--motion-fast)] flex items-center justify-center">
            <Maximize2 className="w-6 h-6 text-white opacity-0 group-hover:opacity-100 transition-opacity duration-[var(--motion-fast)] drop-shadow-lg" />
          </div>
        </div>

        {/* Metadata footer */}
        <div className="px-3 py-2 flex items-center justify-between">
          <div className="flex items-center gap-2 min-w-0">
            {kind === 'photo' ? (
              <Camera className="w-3.5 h-3.5 text-[var(--text-tertiary)] flex-shrink-0" />
            ) : (
              <Image className="w-3.5 h-3.5 text-[var(--text-tertiary)] flex-shrink-0" />
            )}
            <span className="text-xs text-[var(--text-secondary)] truncate">
              {title ?? kind ?? 'Image'}
            </span>
          </div>
          <div className="flex items-center gap-2 flex-shrink-0">
            {dimensions && (
              <span className="text-xs text-[var(--text-tertiary)]">
                {dimensions.w}×{dimensions.h}
              </span>
            )}
            {sizeBytes && (
              <span className="text-xs text-[var(--text-tertiary)]">
                {formatFileSize(sizeBytes)}
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Lightbox modal */}
      {isLightbox && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 animate-[fadeIn_200ms_var(--ease-out)]"
          onClick={closeLightbox}
        >
          {/* Toolbar */}
          <div
            className="absolute top-4 right-4 flex items-center gap-2 z-10"
            onClick={(e) => e.stopPropagation()}
          >
            <button
              onClick={zoomOut}
              className="w-9 h-9 flex items-center justify-center rounded-lg bg-black/50 text-white hover:bg-black/70 transition-colors"
              title="Zoom out"
            >
              <ZoomOut className="w-4 h-4" />
            </button>
            <button
              onClick={resetZoom}
              className="px-2 h-9 flex items-center justify-center rounded-lg bg-black/50 text-white text-xs font-mono hover:bg-black/70 transition-colors min-w-[48px]"
              title="Reset zoom"
            >
              {Math.round(zoom * 100)}%
            </button>
            <button
              onClick={zoomIn}
              className="w-9 h-9 flex items-center justify-center rounded-lg bg-black/50 text-white hover:bg-black/70 transition-colors"
              title="Zoom in"
            >
              <ZoomIn className="w-4 h-4" />
            </button>
            <a
              href={imageUrl}
              download={title}
              className="w-9 h-9 flex items-center justify-center rounded-lg bg-black/50 text-white hover:bg-black/70 transition-colors"
              title="Download"
              onClick={(e) => e.stopPropagation()}
            >
              <Download className="w-4 h-4" />
            </a>
            <button
              onClick={closeLightbox}
              className="w-9 h-9 flex items-center justify-center rounded-lg bg-black/50 text-white hover:bg-black/70 transition-colors"
              title="Close"
            >
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Image */}
          <div
            className="max-w-[90vw] max-h-[90vh] overflow-auto"
            onClick={(e) => e.stopPropagation()}
          >
            <img
              src={imageUrl}
              alt={title ?? 'Capture'}
              className="transition-transform duration-[var(--motion-normal)] origin-center"
              style={{ transform: `scale(${zoom})` }}
            />
          </div>

          {/* Bottom info bar */}
          <div
            className="absolute bottom-4 left-1/2 -translate-x-1/2 px-4 py-2 rounded-lg bg-black/50 text-white text-xs flex items-center gap-4"
            onClick={(e) => e.stopPropagation()}
          >
            {title && <span className="font-medium">{title}</span>}
            {dimensions && <span className="text-white/70">{dimensions.w}×{dimensions.h}</span>}
            {mimeType && <span className="text-white/70">{mimeType}</span>}
            {sizeBytes && <span className="text-white/70">{formatFileSize(sizeBytes)}</span>}
            {uploadedAt && (
              <span className="text-white/70">
                {new Date(uploadedAt).toLocaleString()}
              </span>
            )}
          </div>
        </div>
      )}
    </>
  );
}
