import { useEffect, useState, useCallback, useRef } from 'react';
import { RefreshCw, CheckCircle2, AlertTriangle, XCircle, Shield, Database, HardDrive, Radio, Server, Trash2, Terminal } from 'lucide-react';
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
  environment: { icon: Terminal, label: 'Environment' },
};

function CheckCard({ name, check, onClick }: { name: string; check: HealthCheck; onClick?: () => void }) {
  const meta = checkMeta[name] ?? { icon: Server, label: name };
  const Icon = meta.icon;

  const renderDetails = () => {
    switch (name) {
      case 'secrets':
        return (
          <div className="space-y-1">
            <p>{Number(check.present)} keys present</p>
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
            <p>Latency: {Number(check.latency_ms)}ms</p>
            <p>Migrations applied: {Number(check.migrations_applied)}</p>
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
            <p>Pool: {Number(check.active_streams)} / {Number(check.pool_size)} streams</p>
            <p>Records: {(check.records_total as number)?.toLocaleString() ?? 0}</p>
            <p>Throughput: {(check.throughput_rps as number)?.toFixed(1) ?? 0} rps</p>
            {(check.errors_total as number) > 0 && (
              <p className="text-[var(--accent-error,#BD2B26)]">
                Errors: {Number(check.errors_total)}
              </p>
            )}
          </div>
        );
      case 'app':
        return (
          <div className="space-y-1">
            <p>Name: {String(check.name)}</p>
            <p>Node: {String(check.node_version)}</p>
            <p>Uptime: {formatUptime(check.uptime_s as number)}</p>
          </div>
        );
      case 'environment':
        return (
          <div className="space-y-1">
            <p>{Number(check.total)} variables</p>
          </div>
        );
      case 'sweeper':
        return (
          <div className="space-y-1">
            {check.message ? (
              <p>{String(check.message)}</p>
            ) : (
              <>
                <p>Last run: {check.last_run_at ? new Date(check.last_run_at as string).toLocaleString() : 'Never'}</p>
                <p>Orphans found: {Number(check.orphan_count)}</p>
                <p>Reclaimed: {formatBytes(check.bytes_reclaimed as number)}</p>
                {check.is_stale ? <p className="text-[var(--accent-warning,#FFAB00)]">Stale (&gt;7 days)</p> : null}
              </>
            )}
          </div>
        );
      default:
        return <p>{typeof check.error === "string" ? check.error : JSON.stringify(check)}</p>;
    }
  };

  return (
    <div
      onClick={onClick}
      className="rounded-xl border border-[var(--border-default,#DCE0E2)] bg-[var(--surface-raised,#fff)] p-5
                 cursor-pointer hover:shadow-md hover:border-[var(--border-focus,#2272B4)] transition-all duration-200">
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

function DetailContent({ name, check }: { name: string; check: HealthCheck }) {
  switch (name) {
    case 'secrets':
      return (
        <div className="space-y-3">
          <div className="flex items-center gap-2 mb-2">
            <StatusIcon status={check.status} />
            <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              {check.status === 'ok' ? 'All secrets configured' : 'Missing secrets detected'}
            </span>
          </div>
          <p className="text-sm text-[var(--text-secondary,#5A6F77)]">{Number(check.present)} keys present</p>
          {(check.missing as string[])?.length > 0 && (
            <div className="mt-3">
              <h4 className="text-xs font-medium text-[var(--text-secondary,#5A6F77)] uppercase tracking-wide mb-2">Missing Keys</h4>
              <div className="space-y-1">
                {(check.missing as string[]).map((key) => (
                  <div key={key} className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-[var(--accent-error,#BD2B26)]/5">
                    <XCircle className="w-3.5 h-3.5 text-[var(--accent-error,#BD2B26)]" />
                    <code className="text-xs text-[var(--accent-error,#BD2B26)]">{key}</code>
                  </div>
                ))}
              </div>
            </div>
          )}
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Secrets are managed via the Databricks secret scope. Use the CLI to add missing keys.
          </p>
        </div>
      );

    case 'lakebase':
      return (
        <div className="space-y-3">
          <div className="flex items-center gap-2 mb-2">
            <StatusIcon status={check.status} />
            <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              {check.status === 'ok' ? 'Connected' : 'Connection issue'}
            </span>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Latency</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{Number(check.latency_ms)}ms</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Migrations</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{Number(check.migrations_applied)}</p>
            </div>
          </div>
          {check.error ? (
            <pre className="mt-3 text-xs bg-[var(--surface-tertiary,#EEEDE9)] p-3 rounded-lg overflow-auto text-[var(--accent-error,#BD2B26)]">
              {String(check.error)}
            </pre>
          ) : null}
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            PostgreSQL 17 via Databricks Lakebase. Migrations tracked in app._migrations table.
          </p>
        </div>
      );

    case 'volumes': {
      const vols = check as unknown as Record<string, { status: string; path?: string; configured: boolean; file_count?: number; last_write?: string | null; error?: string }>;
      const entries = Object.entries(vols).filter(([k]) => k !== 'status');
      return (
        <div className="space-y-3">
          {entries.map(([vol, info]) => (
            <div key={vol} className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-4">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <StatusIcon status={info.status} />
                  <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">{vol}</span>
                </div>
                <span className="text-xs text-[var(--text-secondary,#5A6F77)]">
                  {info.configured ? 'Configured' : 'Not configured'}
                </span>
              </div>
              {info.path && (
                <code className="text-xs text-[var(--text-secondary,#5A6F77)] block mb-1 truncate">{info.path}</code>
              )}
              <div className="flex gap-4 text-xs text-[var(--text-secondary,#5A6F77)]">
                {info.file_count !== undefined && <span>Files: {info.file_count}</span>}
                {info.last_write && <span>Last write: {new Date(info.last_write).toLocaleString()}</span>}
              </div>
              {info.error && <p className="text-xs text-[var(--accent-error,#BD2B26)] mt-1">{info.error}</p>}
            </div>
          ))}
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Unity Catalog Volumes store binary uploads (audio, screenshots, documents). File counts from upload records.
          </p>
        </div>
      );
    }

    case 'zerobus':
      return (
        <div className="space-y-3">
          <div className="flex items-center gap-2 mb-2">
            <StatusIcon status={check.status} />
            <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              {check.initialized ? 'Pool initialized' : 'Pool not initialized'}
            </span>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Active Streams</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{Number(check.active_streams)} / {Number(check.pool_size)}</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Throughput</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{(check.throughput_rps as number)?.toFixed(1)} rps</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Records Total</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{(check.records_total as number)?.toLocaleString()}</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Errors</p>
              <p className={`text-lg font-semibold ${(check.errors_total as number) > 0 ? 'text-[var(--accent-error,#BD2B26)]' : 'text-[var(--text-primary,#1B3139)]'}`}>
                {Number(check.errors_total)}
              </p>
            </div>
          </div>
          {check.last_activity_at ? (
            <p className="text-xs text-[var(--text-secondary,#5A6F77)]">
              Last activity: {new Date(String(check.last_activity_at)).toLocaleString()}
            </p>
          ) : null}
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            ZeroBus manages streaming ingestion from iOS devices via connection pooling. Streams activate on device connect.
          </p>
        </div>
      );

    case 'app':
      return (
        <div className="space-y-3">
          <div className="flex items-center gap-2 mb-2">
            <StatusIcon status={check.status} />
            <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">Running</span>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">App Name</p>
              <p className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">{String(check.name)}</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Node Version</p>
              <p className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">{String(check.node_version)}</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Uptime</p>
              <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{formatUptime(check.uptime_s as number)}</p>
            </div>
            <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
              <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Environment</p>
              <p className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">{String(check.environment)}</p>
            </div>
          </div>
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Express + React SPA served via Databricks Apps. OTel telemetry streams to Unity Catalog.
          </p>
        </div>
      );

    case 'sweeper':
      return (
        <div className="space-y-3">
          <div className="flex items-center gap-2 mb-2">
            <StatusIcon status={check.status} />
            <span className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
              {check.message ? String(check.message) : check.is_stale ? 'Stale' : 'Healthy'}
            </span>
          </div>
          {!check.message && (
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Last Run</p>
                <p className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">
                  {check.last_run_at ? new Date(check.last_run_at as string).toLocaleString() : 'Never'}
                </p>
              </div>
              <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Status</p>
                <p className="text-sm font-semibold text-[var(--text-primary,#1B3139)]">{String(check.run_status)}</p>
              </div>
              <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Orphans Found</p>
                <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{Number(check.orphan_count)}</p>
              </div>
              <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                <p className="text-xs text-[var(--text-secondary,#5A6F77)]">Bytes Reclaimed</p>
                <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{formatBytes(check.bytes_reclaimed as number)}</p>
              </div>
            </div>
          )}
          {check.error_message ? (
            <pre className="mt-3 text-xs bg-[var(--surface-tertiary,#EEEDE9)] p-3 rounded-lg overflow-auto text-[var(--accent-error,#BD2B26)]">
              {String(check.error_message)}
            </pre>
          ) : null}
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Scans UC Volumes for orphaned files (no matching upload record). Runs periodically to reclaim storage.
          </p>
        </div>
      );


    case 'environment': {
      const vars = (check.vars ?? {}) as Record<string, { value: string; masked: boolean }>;
      const sorted = Object.entries(vars).sort(([a], [b]) => a.localeCompare(b));
      return (
        <div className="space-y-3">
          <p className="text-sm text-[var(--text-secondary,#5A6F77)]">{sorted.length} variables injected at runtime</p>
          <div className="divide-y divide-[var(--border-default,#DCE0E2)] rounded-lg border border-[var(--border-default,#DCE0E2)] overflow-hidden">
            {sorted.map(([key, info]) => (
              <div key={key} className="flex items-start justify-between gap-2 px-3 py-2 hover:bg-[var(--surface-secondary,#F5F4F0)]">
                <code className="text-xs font-mono text-[var(--text-primary,#1B3139)] break-all">{key}</code>
                <span title={info.value} className={`text-xs font-mono shrink-0 max-w-[400px] truncate ${info.masked ? 'text-[var(--text-secondary,#5A6F77)]' : 'text-[var(--accent-success,#00A972)]'}`}>
                  {info.value || <span className="text-[var(--accent-warning,#FFAB00)]">(empty)</span>}
                </span>
              </div>
            ))}
          </div>
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Shows LAKELOOM_*, DATABRICKS_*, LAKEBASE_* and key Node vars. Secrets are masked (last 4 chars only).
          </p>
        </div>
      );
    }

    case 'environment': {
      const vars = (check.vars ?? {}) as Record<string, { value: string; masked: boolean }>;
      const sorted = Object.entries(vars).sort(([a], [b]) => a.localeCompare(b));
      return (
        <div className="space-y-3">
          <p className="text-sm text-[var(--text-secondary,#5A6F77)]">{sorted.length} variables injected at runtime</p>
          <div className="divide-y divide-[var(--border-default,#DCE0E2)] rounded-lg border border-[var(--border-default,#DCE0E2)] overflow-hidden">
            {sorted.map(([key, info]) => (
              <div key={key} className="flex items-start justify-between gap-2 px-3 py-2 hover:bg-[var(--surface-secondary,#F5F4F0)]">
                <code className="text-xs font-mono text-[var(--text-primary,#1B3139)] break-all">{key}</code>
                <span title={info.value || '(empty)'} className={`text-xs font-mono shrink-0 max-w-[400px] truncate ${info.masked ? 'text-[var(--text-secondary,#5A6F77)]' : 'text-[var(--accent-success,#00A972)]'}`}>
                  {info.value || '(empty)'}
                </span>
              </div>
            ))}
          </div>
          <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-4 italic">
            Shows LAKELOOM_*, DATABRICKS_*, LAKEBASE_* and key Node vars. Secrets are masked (last 4 chars only).
          </p>
        </div>
      );
    }

    default:
      return <pre className="text-xs overflow-auto">{JSON.stringify(check, null, 2)}</pre>;
  }
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

  // Detail modal state (must be before any early return - Rules of Hooks)
  const [detailTarget, setDetailTarget] = useState<string | null>(null);

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

  const detailCheck = detailTarget && health ? health.checks[detailTarget] as HealthCheck : null;

  return (
    <div className="max-w-4xl mx-auto px-6 py-6">
      {/* Detail modal */}
      {detailTarget && detailCheck && (
        <div className="fixed inset-0 z-50 flex items-center justify-center">
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={() => setDetailTarget(null)} />
          <div className="relative w-full max-w-2xl max-h-[80vh] overflow-y-auto mx-4
                          bg-[var(--surface-raised,#fff)] rounded-2xl shadow-2xl
                          border border-[var(--border-default,#DCE0E2)]
                          animate-[scaleIn_200ms_cubic-bezier(0.16,1,0.3,1)]">
            {/* Modal header */}
            <div className="sticky top-0 z-10 flex items-center justify-between px-6 py-4
                            bg-[var(--surface-raised,#fff)] border-b border-[var(--border-default,#DCE0E2)] rounded-t-2xl">
              <div className="flex items-center gap-2">
                {(() => { const Icon = (checkMeta[detailTarget] ?? checkMeta.app).icon; return <Icon className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />; })()}
                <h2 className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">
                  {(checkMeta[detailTarget] ?? { label: detailTarget }).label}
                </h2>
              </div>
              <button onClick={() => setDetailTarget(null)} className="p-1.5 rounded-lg hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100">
                <XCircle className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
              </button>
            </div>
            {/* Modal body */}
            <div className="px-6 py-5">
              <DetailContent name={detailTarget} check={detailCheck} />
            </div>
          </div>
        </div>
      )}

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
              <CheckCard key={name} name={name} check={check as HealthCheck} onClick={() => setDetailTarget(name)} />
            ))}
          </div>
        </>
      )}
    </div>
  );
}
