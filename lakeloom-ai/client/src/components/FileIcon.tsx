/**
 * FileIcon — MIME-type-aware file icon with kind differentiation.
 *
 * Uses lucide-react icons with semantic color accents per file type.
 * Supports the lakeLoom upload kinds: audio, screenshot, photo, document.
 */

import { cn } from '../lib/utils';
import { Music, Image, Camera, FileText, File } from 'lucide-react';
import type { ReactNode } from 'react';

type UploadKind = 'audio' | 'screenshot' | 'photo' | 'document';

interface FileIconProps {
  /** Upload kind from app.uploads table */
  kind?: UploadKind | string;
  /** MIME type (fallback detection when kind is unknown) */
  mimeType?: string;
  /** Icon size in pixels (default: 20) */
  size?: number;
  className?: string;
}

interface IconConfig {
  icon: ReactNode;
  colorClass: string;
  bgClass: string;
}

function resolveKind(kind?: string, mimeType?: string): UploadKind {
  if (kind && ['audio', 'screenshot', 'photo', 'document'].includes(kind)) {
    return kind as UploadKind;
  }
  // Fallback: detect from MIME type
  if (mimeType) {
    if (mimeType.startsWith('audio/')) return 'audio';
    if (mimeType.startsWith('image/')) return 'screenshot';
    if (mimeType === 'application/pdf' || mimeType.includes('wordprocessing')) return 'document';
  }
  return 'document';
}

function getConfig(kind: UploadKind, size: number): IconConfig {
  switch (kind) {
    case 'audio':
      return {
        icon: <Music size={size} />,
        colorClass: 'text-[var(--accent-primary,#FF3621)]',
        bgClass: 'bg-[#FF36211a]',
      };
    case 'screenshot':
      return {
        icon: <Image size={size} />,
        colorClass: 'text-[var(--accent-info,#2272B4)]',
        bgClass: 'bg-[#2272B41a]',
      };
    case 'photo':
      return {
        icon: <Camera size={size} />,
        colorClass: 'text-[var(--accent-success,#00A972)]',
        bgClass: 'bg-[#00A9721a]',
      };
    case 'document':
      return {
        icon: <FileText size={size} />,
        colorClass: 'text-[var(--accent-warning,#FFAB00)]',
        bgClass: 'bg-[#FFAB001a]',
      };
    default:
      return {
        icon: <File size={size} />,
        colorClass: 'text-[var(--text-secondary,#5A6F77)]',
        bgClass: 'bg-[var(--surface-tertiary,#EEEDE9)]',
      };
  }
}

/**
 * Renders the file icon inline (no background container).
 */
export function FileIcon({ kind, mimeType, size = 20, className }: FileIconProps) {
  const resolved = resolveKind(kind, mimeType);
  const config = getConfig(resolved, size);

  return (
    <span className={cn('inline-flex items-center', config.colorClass, className)}>
      {config.icon}
    </span>
  );
}

/**
 * Renders the file icon inside a rounded container (for timeline views).
 */
export function FileIconContainer({ kind, mimeType, size = 16, className }: FileIconProps) {
  const resolved = resolveKind(kind, mimeType);
  const config = getConfig(resolved, size);

  return (
    <span
      className={cn(
        'inline-flex items-center justify-center w-8 h-8 rounded-lg',
        config.bgClass,
        config.colorClass,
        className,
      )}
    >
      {config.icon}
    </span>
  );
}
