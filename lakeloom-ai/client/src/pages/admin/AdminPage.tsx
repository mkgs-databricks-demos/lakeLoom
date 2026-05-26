import { useEffect, useState, useCallback, useRef } from 'react';
import { RefreshCw, CheckCircle2, AlertTriangle, XCircle, Shield, Database, HardDrive, Radio, Server, Trash2 } from 'lucide-react';
import { Skeleton } from '@databricks/appkit-ui/react';

interface HealthCheck {
  status: string;
  [key: string]: unknown;
}

interface HealthResponse {
  status: 'healthy' | 'degraded' | 'unhealthy';
  checks: Record<string, HealthCheck>;
  timestamp: string;
}

function StatusIcon({ status }: { status: string }) {
  switch (status) {
    case 'ok':
      return <CheckCircle2 className="w-5 h-5 text-[var(--accent-success,#00A972)]" />;
    case 'warning':
      return <AlertTriangle className="w-5 h-5 text-[var(--accent-warning,#FFAB00)]" />;
    case 'error':
      return <XCircle className="w-5 h-5 text-[var(--accent-error,#BD2B26)]" />;
    default:
      return <CheckCircle2 className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />;
  }
}

function OverallStatusBanner({ status }: { status: string }) {
  const config = {
    healthy: { color: 'var(--accent-success,#00A972)', label: 'All systems healthy', bg: 'bg-green-50' },
    degraded: { color: 'var(--accent-warning,#FFAB00)', label: 'Some systems degraded', bg: 'bg-amber-50' },
    unhealthy: { color: 'var(--accent-error,#BD2B26)', label: 'Systems unhealthy', bg: 'bg-red-50' },
  }[status] ?? { color: 'var(--text-secondary)', label: 'Unknown', bg: 'bg-gray-50' };

  return (
    <div className={`flex items-center gap-3 px-5 py-4 rounded-xl border border-[var(--border-default,#DCE0E2)] ${config.bg}`}>
      <div className="w-4 h-4 rounded-full animate-pulse" style={{ backgroundColor: config.color }} />
      <span className="text-base font-semibold" style={{ color: config.color }}>
        {config.label}
      </span>
    </div>
  );
}

function formatUptime(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return `${(bytes / Math.pow(1024, i)).toFixed(1)} ${units[i]}`;
}

const checkMeta: Record<string, { icon: typeof Shield; label: string }> = {
  secrets: { icon: Shield, label: 'Secrets' },
  lakebase: { icon: Database, label: 'Lakebase' },
  volumes: { icon: HardDrive, label: 'Volumes' },
  zerobus: { icon: Radio, label: 'ZeroBus' },
  app: { icon: Server, label: 'Application' },
  sweeper: { icon: Trash2, label: 'Orphan Sweeper' },
};

function CheckCard({ name, check }: { name: string; check: HealthCheck }) {
  const meta = checkMeta[name] ?? { icon: Server, label: name };
  const Icon = meta.icon;

  const renderDetails = () => {
    switch (name) {
      case 'secrets':
        return (
          <div className="space-y-1">
            <p>{check.present as number} keys present</p>
            {(check.missing as string[])?.length > 0 && (
              <p className="text-[var(--accent-error,#BD2B26)]">
                Missing: {(check.missing as string[]).join(', ')}
              </p>
            )}
          </div>
        );
      case 'lakebase':
        return (
          <div className="space-y-1">
            <p>Latency: {check.latency_ms as number}ms</p>
            <p>Migrations applied: {check.migrations_applied as number}</p>
          </div>
        );
      case 'volumes': {
        const vols = check as unknown as Record<string, { status: string; path?: string; error?: string }>;
        return (
          <div className="space-y-1">
            {Object.entries(vols).filter(([k]) => k !== 'status').map(([vol, info]) => (
              <div key={vol} className="flex items-center gap-2">
                <StatusIcon status={info.status} />
                <span>{vol}</span>
              </div>
            ))}
          </div>
        );
      }
      case 'zerobus':
        return (
          <div className="space-y-1">
            <p>Pool: {check.active_streams as number} / {check.pool_size as number} streams</p>
            <p>Records: {(check.records_total as number)?.toLocaleString() ?? 0}</p>
            <p>Throughput: {(check.throughput_rps as number)?.toFixed(1) ?? 0} rps</p>
            {(check.errors_total as number) > 0 && (
              <p className="text-[var(--accent-error,#BD2B26)]">
                Errors: {check.errors_total as number}
              </p>
            )}
          </div>
        );
      case 'app':
        return (
          <div className="space-y-1">
            <p>Name: {check.name as string}</p>
            <p>Node: {check.node_version as string}</p>
            <p>Uptime: {formatUptime(check.uptime_s as number)}</p>
          </div>
        );
      case 'sweeper':
        return (
          <div className="space-y-1">
            {check.message ? (
              <p>{check.message as string}</p>
            ) : (
              <>
                <p>Last run: {check.last_run_at ? new Date(check.last_run_at as string).toLocaleString() : 'Never'}</p>
                <p>Orphans found: {check.orphan_count as number}</p>
                <p>Reclaimed: {formatBytes(check.bytes_reclaimed as number)}</p>
                {check.is_stale && <p className="text-[var(--accent-warning,#FFAB00)]">Stale (&gt;7 days)</p>}
              </>
            )}
          </div>
        );
      default:
        return <p>{check.error as string ?? JSON.stringify(check)}</p>;
    }
  };

  return (
    <div className="rounded-xl border border-[var(--border-default,#DCE0E2)] bg-[var(--surface-raised,#fff)] p-5">
      <div className="flex items-center gap-3 mb-3">
        <Icon className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
        <h3 className="font-medium text-[var(--text-primary,#1B3139)] text-sm flex-1">
          {meta.label}
        </h3>
        <StatusIcon status={check.status} />
      </div>
      <div className="text-xs text-[var(--text-secondary,#5A6F77)]">
        {renderDetails()}
      </div>
    </div>
  );
}

export function AdminPage() {
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [autoRefresh, setAutoRefresh] = useState(false);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const fetchHealth = useCallback(async (isManual = false) => {
    if (isManual) setRefreshing(true);
    try {
      const res = await fetch('/api/admin/health');
      if (!res.ok) throw new Error(`${res.status}`);
      const data = await res.json();
      setHealth(data);
    } catch (err) {
      console.error('[AdminPage] fetch error:', err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => { fetchHealth(); }, [fetchHealth]);

  useEffect(() => {
    if (autoRefresh) {
      intervalRef.current = setInterval(() => fetchHealth(), 30_000);
    } else if (intervalRef.current) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
    return () => { if (intervalRef.current) clearInterval(intervalRef.current); };
  }, [autoRefresh, fetchHealth]);

  if (loading) {
    return (
      <div className="max-w-4xl mx-auto px-6 py-6 space-y-4">
        <Skeleton className="h-16 w-full rounded-xl" />
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {[1, 2, 3, 4, 5, 6].map((i) => (
            <Skeleton key={i} className="h-36 rounded-xl" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto px-6 py-6">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-xl font-bold text-[var(--text-primary,#1B3139)]">
          System Health
        </h1>
        <div className="flex items-center gap-3">
          {/* Auto-refresh toggle */}
          <label className="flex items-center gap-2 text-xs text-[var(--text-secondary,#5A6F77)] cursor-pointer">
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={(e) => setAutoRefresh(e.target.checked)}
              className="rounded"
            />
            Auto-refresh
          </label>
          {/* Manual refresh */}
          <button
            type="button"
            onClick={() => fetchHealth(true)}
            disabled={refreshing}
            className="inline-flex items-center gap-2 px-3 py-1.5 rounded-lg
                       border border-[var(--border-default,#DCE0E2)] text-sm font-medium
                       text-[var(--text-primary,#1B3139)] hover:bg-[var(--surface-tertiary,#EEEDE9)]
                       transition-colors duration-100 disabled:opacity-50"
          >
            <RefreshCw className={`w-4 h-4 ${refreshing ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>
      </div>

      {/* Overall status */}
      {health && (
        <>
          <div className="mb-6">
            <OverallStatusBanner status={health.status} />
            <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-2">
              Last checked: {new Date(health.timestamp).toLocaleString()}
            </p>
          </div>

          {/* Check cards grid */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {Object.entries(health.checks).map(([name, check]) => (
              <CheckCard key={name} name={name} check={check as HealthCheck} />
            ))}
          </div>
        </>
      )}
    </div>
  );
}
