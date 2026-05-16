/**
 * EmptyState — centered placeholder for views with no data.
 *
 * Brand spec: 64px icon container with --surface-tertiary bg,
 * DM Sans Semibold 18px title, 14px secondary description,
 * max-width 28rem, py-16 vertical padding.
 */

import { cn } from '../lib/utils';
import type { ReactNode } from 'react';

interface EmptyStateProps {
  /** Icon rendered inside the 64px container */
  icon?: ReactNode;
  /** Primary heading */
  title: string;
  /** Secondary descriptive text */
  description: string;
  /** Optional CTA button or link */
  action?: ReactNode;
  className?: string;
}

export function EmptyState({ icon, title, description, action, className }: EmptyStateProps) {
  return (
    <div className={cn('flex flex-col items-center justify-center py-16 px-6 text-center', className)}>
      {icon && (
        <div className="w-16 h-16 rounded-2xl bg-[var(--surface-tertiary,#EEEDE9)] flex items-center justify-center mb-4 text-[var(--text-secondary,#5A6F77)]">
          {icon}
        </div>
      )}
      <h3 className="text-lg font-semibold text-[var(--text-primary,#1B3139)] mb-1">
        {title}
      </h3>
      <p className="text-sm text-[var(--text-secondary,#5A6F77)] max-w-md mb-6">
        {description}
      </p>
      {action}
    </div>
  );
}
