/**
 * StatusBadge — capture session state indicator.
 *
 * Brand spec: DM Sans Medium 12px, rounded-full pill, semantic color tokens.
 * Active state includes a subtle pulse animation to indicate a live capture.
 */

import { cn } from '../lib/utils';

type CaptureState = 'active' | 'completed' | 'cancelled';

interface StatusBadgeProps {
  state: CaptureState;
  className?: string;
}

const stateConfig: Record<CaptureState, { label: string; classes: string; dot?: boolean }> = {
  active: {
    label: 'Active',
    classes: 'bg-[var(--accent-success-subtle,#dcfce7)] text-[var(--accent-success,#00A972)]',
    dot: true,
  },
  completed: {
    label: 'Completed',
    classes: 'bg-[var(--accent-info-subtle,#dbeafe)] text-[var(--accent-info,#2272B4)]',
  },
  cancelled: {
    label: 'Cancelled',
    classes: 'bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-secondary,#5A6F77)]',
  },
};

export function StatusBadge({ state, className }: StatusBadgeProps) {
  const config = stateConfig[state] ?? stateConfig.cancelled;

  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium',
        config.classes,
        className,
      )}
    >
      {config.dot && (
        <span className="relative flex h-2 w-2">
          <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-current opacity-75" />
          <span className="relative inline-flex rounded-full h-2 w-2 bg-current" />
        </span>
      )}
      {config.label}
    </span>
  );
}
