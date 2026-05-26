import { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router';
import { Smartphone, Trash2, Plus, Wifi, WifiOff, ShieldOff } from 'lucide-react';
import { Skeleton } from '@databricks/appkit-ui/react';
import { ConfirmDialog } from '../../components/ConfirmDialog';

interface PairedDevice {
  id: string;
  label: string;
  first_seen_at: string | null;
  last_seen_at: string | null;
  expires_at: string;
  paired_at: string;
  revoked_at: string | null;
}

function timeAgo(dateStr: string | null): string {
  if (!dateStr) return 'Never';
  const diff = Date.now() - new Date(dateStr).getTime();
  const minutes = Math.floor(diff / 60_000);
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function timeUntil(dateStr: string): string {
  const diff = new Date(dateStr).getTime() - Date.now();
  if (diff <= 0) return 'Expired';
  const hours = Math.floor(diff / 3_600_000);
  if (hours < 24) return `${hours}h remaining`;
  const days = Math.floor(hours / 24);
  return `${days}d remaining`;
}

function isActiveNow(lastSeen: string | null): boolean {
  if (!lastSeen) return false;
  return Date.now() - new Date(lastSeen).getTime() < 5 * 60_000;
}

function isExpiringSoon(expiresAt: string): boolean {
  return new Date(expiresAt).getTime() - Date.now() < 24 * 60 * 60_000;
}

function isExpired(expiresAt: string): boolean {
  return new Date(expiresAt).getTime() <= Date.now();
}

export function DevicesPage() {
  const [devices, setDevices] = useState<PairedDevice[]>([]);
  const [loading, setLoading] = useState(true);
  const [showRevoked, setShowRevoked] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<PairedDevice | null>(null);
  const [revoking, setRevoking] = useState(false);
  const navigate = useNavigate();

  const fetchDevices = useCallback(async () => {
    try {
      const params = showRevoked ? '?include_revoked=true' : '';
      const res = await fetch(`/api/pairing/devices${params}`);
      if (!res.ok) throw new Error(`${res.status}`);
      const data = await res.json();
      setDevices(data.devices);
    } catch (err) {
      console.error('[DevicesPage] fetch error:', err);
    } finally {
      setLoading(false);
    }
  }, [showRevoked]);

  useEffect(() => { fetchDevices(); }, [fetchDevices]);

  const handleRevoke = async () => {
    if (!revokeTarget) return;
    setRevoking(true);
    try {
      const res = await fetch(`/api/pairing/devices/${revokeTarget.id}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setDevices((prev) => prev.filter((d) => d.id !== revokeTarget.id));
      }
    } catch (err) {
      console.error('[DevicesPage] revoke error:', err);
    } finally {
      setRevoking(false);
      setRevokeTarget(null);
    }
  };

  // ── Loading state ───────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="max-w-5xl mx-auto px-6 py-6">
        <div className="flex items-center justify-between mb-6">
          <Skeleton className="h-8 w-48" />
          <Skeleton className="h-9 w-36" />
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[1, 2, 3].map((i) => (
            <Skeleton key={i} className="h-40 rounded-xl" />
          ))}
        </div>
      </div>
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────────
  if (devices.length === 0 && !showRevoked) {
    return (
      <div className="max-w-5xl mx-auto px-6 py-16 flex flex-col items-center gap-4">
        <div className="w-16 h-16 rounded-full bg-[var(--surface-tertiary,#EEEDE9)] flex items-center justify-center">
          <Smartphone className="w-8 h-8 text-[var(--text-secondary,#5A6F77)]" />
        </div>
        <h2 className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">
          No devices paired yet
        </h2>
        <p className="text-sm text-[var(--text-secondary,#5A6F77)] max-w-sm text-center">
          Pair your first device to start capturing requirements, architecture decisions, and session recordings.
        </p>
        <button
          type="button"
          onClick={() => navigate('/pairing')}
          className="mt-2 inline-flex items-center gap-2 px-4 py-2 rounded-lg
                     bg-[var(--accent-primary,#FF3621)] text-white text-sm font-medium
                     hover:opacity-90 transition-opacity duration-100"
        >
          <Plus className="w-4 h-4" />
          Pair your first device
        </button>
      </div>
    );
  }

  // ── Device grid ─────────────────────────────────────────────────────────
  return (
    <div className="max-w-5xl mx-auto px-6 py-6">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-xl font-bold text-[var(--text-primary,#1B3139)]">
          Paired Devices
        </h1>
        <div className="flex items-center gap-3">
          {/* Show revoked toggle */}
          <label className="flex items-center gap-2 text-xs text-[var(--text-secondary,#5A6F77)] cursor-pointer">
            <input
              type="checkbox"
              checked={showRevoked}
              onChange={(e) => setShowRevoked(e.target.checked)}
              className="rounded"
            />
            Show revoked
          </label>
          <button
            type="button"
            onClick={() => navigate('/pairing')}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-lg
                       bg-[var(--accent-primary,#FF3621)] text-white text-sm font-medium
                       hover:opacity-90 transition-opacity duration-100"
          >
            <Plus className="w-4 h-4" />
            Pair new device
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {devices.map((device) => {
          const isRevoked = device.revoked_at !== null;
          const active = !isRevoked && isActiveNow(device.last_seen_at);
          const expiringSoon = !isRevoked && isExpiringSoon(device.expires_at);
          const expired = !isRevoked && isExpired(device.expires_at);

          return (
            <div
              key={device.id}
              className={`group relative rounded-xl border border-[var(--border-default,#DCE0E2)]
                         bg-[var(--surface-raised,#fff)] p-5 transition-shadow duration-200
                         hover:shadow-md ${isRevoked ? 'opacity-50' : ''}`}
            >
              {/* Header */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-center gap-2">
                  <Smartphone className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
                  <h3 className="font-medium text-[var(--text-primary,#1B3139)] text-sm">
                    {device.label}
                  </h3>
                </div>
                {!isRevoked && (
                  <button
                    type="button"
                    onClick={() => setRevokeTarget(device)}
                    className="opacity-0 group-hover:opacity-100 p-1.5 rounded-md
                               text-[var(--text-secondary,#5A6F77)] hover:text-[var(--accent-error,#BD2B26)]
                               hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-all duration-100"
                    title="Revoke device"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
              </div>

              {/* Status badge */}
              <div className="flex items-center gap-1.5 mb-3">
                {isRevoked ? (
                  <>
                    <ShieldOff className="w-3.5 h-3.5 text-[var(--accent-error,#BD2B26)]" />
                    <span className="text-xs font-medium text-[var(--accent-error,#BD2B26)]">
                      Revoked {timeAgo(device.revoked_at)}
                    </span>
                  </>
                ) : active ? (
                  <>
                    <Wifi className="w-3.5 h-3.5 text-[var(--accent-success,#00A972)]" />
                    <span className="text-xs font-medium text-[var(--accent-success,#00A972)]">
                      Active now
                    </span>
                  </>
                ) : (
                  <>
                    <WifiOff className="w-3.5 h-3.5 text-[var(--text-secondary,#5A6F77)]" />
                    <span className="text-xs text-[var(--text-secondary,#5A6F77)]">
                      Last seen {timeAgo(device.last_seen_at)}
                    </span>
                  </>
                )}
              </div>

              {/* Details */}
              <div className="space-y-1 text-xs text-[var(--text-secondary,#5A6F77)]">
                <p>Paired {timeAgo(device.paired_at)}</p>
                {!isRevoked && (
                  <p className={expired ? 'text-[var(--accent-error,#BD2B26)] font-medium' : expiringSoon ? 'text-[var(--accent-warning,#FFAB00)] font-medium' : ''}>
                    {expired ? 'Expired' : expiringSoon ? `\u26a0 Expiring soon (${timeUntil(device.expires_at)})` : `Expires in ${timeUntil(device.expires_at)}`}
                  </p>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Revoke confirmation */}
      <ConfirmDialog
        open={revokeTarget !== null}
        title="Revoke device"
        description={`This will permanently revoke "${revokeTarget?.label ?? ''}". The device will need to be re-paired to connect again.`}
        confirmLabel="Revoke"
        onConfirm={handleRevoke}
        onClose={() => setRevokeTarget(null)}
        loading={revoking}
        variant="danger"
      />
    </div>
  );
}
