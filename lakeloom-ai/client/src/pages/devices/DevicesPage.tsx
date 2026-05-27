/**
 * DevicesPage — Device management grid with detail drawer.
 *
 * Features:
 *   - Device grid with status badges (Active now / Last seen / Expired)
 *   - "Show my devices" toggle (on by default); shows all users when off
 *   - "Pair new device" button opens PairDeviceModal (QR inline)
 *   - Clickable cards open a slide-out detail drawer with:
 *     • Device stats (projects, uploads, captures breakdown)
 *     • Most recent project
 *     • Editable device name (inline rename)
 *     • Extend expiry button (+7 days)
 *     • Re-pair button — generates inline QR to re-activate an existing device
 *       (avoids duplicates after expiration/app reinstall). SSE confirms in real-time.
 *   - Username display on each card
 *   - Revoke with confirmation dialog
 *   - Expiry warnings (<24h = amber)
 *   - Show revoked toggle
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useEffect, useState, useCallback, useRef } from 'react';
import {
  Smartphone, Trash2, Plus, Wifi, WifiOff, ShieldOff, RefreshCw,
  X, Pencil, Check, FolderOpen, Upload, Video, User, Clock,
} from 'lucide-react';
import { Skeleton } from '@databricks/appkit-ui/react';
import { QRCodeSVG } from 'qrcode.react';
import { ConfirmDialog } from '../../components/ConfirmDialog';
import { PairDeviceModal } from '../../components/PairDeviceModal';

// ── Types ───────────────────────────────────────────────────────────────────────

interface PairedDevice {
  id: string;
  label: string;
  first_seen_at: string | null;
  last_seen_at: string | null;
  expires_at: string;
  paired_at: string;
  revoked_at: string | null;
  username: string | null;
  user_id: string;
  is_mine: boolean;
}

interface DeviceStats {
  device_id: string;
  project_count: number;
  upload_count: number;
  capture_count: number;
  captures: { completed: number; active: number; cancelled: number };
  upload_kinds: Record<string, number>;
  most_recent_project: { id: string; name: string; assigned_at: string } | null;
}

// ── Helpers ─────────────────────────────────────────────────────────────────────

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

// ── Component ───────────────────────────────────────────────────────────────────

export function DevicesPage() {
  const [devices, setDevices] = useState<PairedDevice[]>([]);
  const [loading, setLoading] = useState(true);
  const [showMyDevices, setShowMyDevices] = useState(true);
  const [showRevoked, setShowRevoked] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<PairedDevice | null>(null);
  const [revoking, setRevoking] = useState(false);
  const [pairModalOpen, setPairModalOpen] = useState(false);

  // Detail drawer state
  const [selectedDevice, setSelectedDevice] = useState<PairedDevice | null>(null);
  const [deviceStats, setDeviceStats] = useState<DeviceStats | null>(null);
  const [statsLoading, setStatsLoading] = useState(false);

  // Inline rename state
  const [editingName, setEditingName] = useState(false);
  const [nameInput, setNameInput] = useState('');
  const [renaming, setRenaming] = useState(false);

  // Extend expiry state
  const [extending, setExtending] = useState(false);

  // Re-pair state
  const [repairing, setRepairing] = useState(false);
  const [repairQrData, setRepairQrData] = useState<string | null>(null);

  // ── Fetch devices ───────────────────────────────────────────────────────
  const fetchDevices = useCallback(async () => {
    try {
      const params = new URLSearchParams();
      if (showRevoked) params.set('include_revoked', 'true');
      if (!showMyDevices) params.set('all_users', 'true');
      const qs = params.toString() ? `?${params.toString()}` : '';
      const res = await fetch(`/api/pairing/devices${qs}`);
      if (!res.ok) throw new Error(`${res.status}`);
      const data = await res.json();
      setDevices(data.devices);
    } catch (err) {
      console.error('[DevicesPage] fetch error:', err);
    } finally {
      setLoading(false);
    }
  }, [showRevoked, showMyDevices]);

  useEffect(() => { fetchDevices(); }, [fetchDevices]);


  // ── SSE for re-pair confirmation ────────────────────────────────────────
  const repairEventSourceRef = useRef<EventSource | null>(null);
  useEffect(() => {
    if (!repairQrData) {
      // Close SSE when QR is dismissed
      if (repairEventSourceRef.current) {
        repairEventSourceRef.current.close();
        repairEventSourceRef.current = null;
      }
      return;
    }

    const es = new EventSource('/api/pairing/events');
    repairEventSourceRef.current = es;
    es.addEventListener('device_paired', (event) => {
      const data = JSON.parse(event.data);
      // Device re-paired — refresh list, clear QR, update drawer
      setRepairQrData(null);
      fetchDevices();
      if (selectedDevice && data.paired_session_id === selectedDevice.id) {
        setSelectedDevice((prev) => prev ? { ...prev, revoked_at: null } : prev);
      }
    });

    return () => {
      es.close();
      repairEventSourceRef.current = null;
    };
  }, [repairQrData, fetchDevices, selectedDevice]);

  // ── Fetch device stats ──────────────────────────────────────────────────
  const openDetail = async (device: PairedDevice) => {
    setSelectedDevice(device);
    setRepairQrData(null);
    setDeviceStats(null);
    setEditingName(false);
    setStatsLoading(true);
    try {
      const res = await fetch(`/api/pairing/devices/${device.id}/stats`);
      if (res.ok) {
        setDeviceStats(await res.json());
      }
    } catch (err) {
      console.error('[DevicesPage] stats fetch error:', err);
    } finally {
      setStatsLoading(false);
    }
  };

  const closeDetail = () => {
    setSelectedDevice(null);
    setDeviceStats(null);
    setEditingName(false);
  };

  // ── Rename ──────────────────────────────────────────────────────────────
  const startRename = () => {
    setEditingName(true);
    setNameInput(selectedDevice?.label ?? '');
  };

  const submitRename = async () => {
    if (!selectedDevice || !nameInput.trim()) return;
    setRenaming(true);
    try {
      const res = await fetch(`/api/pairing/devices/${selectedDevice.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ label: nameInput.trim() }),
      });
      if (res.ok) {
        const updated = await res.json();
        setDevices((prev) => prev.map((d) => d.id === selectedDevice.id ? { ...d, label: updated.label } : d));
        setSelectedDevice((prev) => prev ? { ...prev, label: updated.label } : prev);
        setEditingName(false);
      }
    } catch (err) {
      console.error('[DevicesPage] rename error:', err);
    } finally {
      setRenaming(false);
    }
  };

  // ── Extend expiry ───────────────────────────────────────────────────────
  const handleExtend = async (days: number = 7) => {
    if (!selectedDevice) return;
    setExtending(true);
    try {
      const res = await fetch(`/api/pairing/devices/${selectedDevice.id}/extend`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ days }),
      });
      if (res.ok) {
        const data = await res.json();
        const newExpiry = data.expires_at;
        // Update device in list and in drawer
        setDevices((prev) => prev.map((d) => d.id === selectedDevice.id ? { ...d, expires_at: newExpiry } : d));
        setSelectedDevice((prev) => prev ? { ...prev, expires_at: newExpiry } : prev);
      }
    } catch (err) {
      console.error('[DevicesPage] extend error:', err);
    } finally {
      setExtending(false);
    }
  };


  // ── Re-pair device ────────────────────────────────────────────────────
  const handleRepair = async () => {
    if (!selectedDevice) return;
    setRepairing(true);
    setRepairQrData(null);
    try {
      const res = await fetch(`/api/pairing/devices/${selectedDevice.id}/repair`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });
      if (res.ok) {
        const payload = await res.json();
        setRepairQrData(JSON.stringify(payload));
        // Update device in list — now awaiting confirmation (no pubkey)
        setDevices((prev) => prev.map((d) =>
          d.id === selectedDevice.id ? { ...d, expires_at: payload.session.expires_at, revoked_at: null } : d
        ));
        setSelectedDevice((prev) => prev ? { ...prev, expires_at: payload.session.expires_at, revoked_at: null } : prev);
      }
    } catch (err) {
      console.error('[DevicesPage] repair error:', err);
    } finally {
      setRepairing(false);
    }
  };

  // ── Revoke ──────────────────────────────────────────────────────────────
  const handleRevoke = async () => {
    if (!revokeTarget) return;
    setRevoking(true);
    try {
      const res = await fetch(`/api/pairing/devices/${revokeTarget.id}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setDevices((prev) => prev.filter((d) => d.id !== revokeTarget.id));
        if (selectedDevice?.id === revokeTarget.id) closeDetail();
      }
    } catch (err) {
      console.error('[DevicesPage] revoke error:', err);
    } finally {
      setRevoking(false);
      setRevokeTarget(null);
    }
  };

  // ── Loading state ────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="max-w-6xl mx-auto px-6 py-6">
        <div className="flex items-center justify-between mb-6">
          <Skeleton className="h-8 w-48" />
          <Skeleton className="h-9 w-36" />
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[1, 2, 3].map((i) => (
            <Skeleton key={i} className="h-44 rounded-xl" />
          ))}
        </div>
      </div>
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────────
  if (devices.length === 0 && !showRevoked) {
    return (
      <div className="max-w-6xl mx-auto px-6 py-16 flex flex-col items-center gap-4">
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
          onClick={() => setPairModalOpen(true)}
          className="mt-2 inline-flex items-center gap-2 px-4 py-2 rounded-lg
                     bg-[var(--accent-primary,#FF3621)] text-white text-sm font-medium
                     hover:opacity-90 transition-opacity duration-100"
        >
          <Plus className="w-4 h-4" />
          Pair your first device
        </button>
        <PairDeviceModal open={pairModalOpen} onClose={() => { setPairModalOpen(false); fetchDevices(); }} />
      </div>
    );
  }

  // ── Main grid ───────────────────────────────────────────────────────────
  return (
    <div className="max-w-6xl mx-auto px-6 py-6">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-xl font-bold text-[var(--text-primary,#1B3139)]">
          Paired Devices
        </h1>
        <div className="flex items-center gap-3">
          {/* Show my devices toggle */}
          <label className="flex items-center gap-2 text-xs text-[var(--text-secondary,#5A6F77)] cursor-pointer">
            <input
              type="checkbox"
              checked={showMyDevices}
              onChange={(e) => setShowMyDevices(e.target.checked)}
              className="rounded"
            />
            My devices
          </label>
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
            onClick={() => setPairModalOpen(true)}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-lg
                       bg-[var(--accent-primary,#FF3621)] text-white text-sm font-medium
                       hover:opacity-90 transition-opacity duration-100"
          >
            <Plus className="w-4 h-4" />
            Pair new device
          </button>
        </div>
      </div>

      {/* Device grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {devices.map((device) => {
          const isRevoked = device.revoked_at !== null;
          const active = !isRevoked && isActiveNow(device.last_seen_at);
          const expiringSoon = !isRevoked && isExpiringSoon(device.expires_at);
          const expired = !isRevoked && isExpired(device.expires_at);

          return (
            <div
              key={device.id}
              onClick={() => openDetail(device)}
              className={`group relative rounded-xl border border-[var(--border-default,#DCE0E2)]
                         bg-[var(--surface-raised,#fff)] p-5 transition-all duration-200
                         hover:shadow-md hover:border-[var(--border-focus,#2272B4)] cursor-pointer
                         ${isRevoked ? 'opacity-50' : ''}
                         ${selectedDevice?.id === device.id ? 'ring-2 ring-[var(--border-focus,#2272B4)]' : ''}`}
            >
              {/* Header */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex items-center gap-2">
                  <Smartphone className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
                  <h3 className="font-medium text-[var(--text-primary,#1B3139)] text-sm">
                    {device.label}
                  </h3>
                </div>
                {!isRevoked && device.is_mine && (
                  <button
                    type="button"
                    onClick={(e) => { e.stopPropagation(); setRevokeTarget(device); }}
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
              <div className="flex items-center gap-1.5 mb-2">
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

              {/* Username attribution */}
              {device.username && (
                <div className="mt-3 pt-3 border-t border-[var(--border-default,#DCE0E2)] flex items-center gap-1.5">
                  <User className="w-3 h-3 text-[var(--text-secondary,#5A6F77)]" />
                  <span className="text-[11px] text-[var(--text-secondary,#5A6F77)] truncate">
                    {device.username}
                  </span>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* ── Detail Drawer (slide-out from right) ─────────────────────── */}
      {selectedDevice && (
        <div className="fixed inset-0 z-40 flex justify-end">
          {/* Backdrop */}
          <div className="absolute inset-0 bg-black/20" onClick={closeDetail} />
          {/* Drawer */}
          <div className="relative w-full max-w-md bg-[var(--surface-raised,#fff)] shadow-2xl
                          border-l border-[var(--border-default,#DCE0E2)] overflow-y-auto
                          animate-[slideInRight_200ms_ease-out]">
            {/* Drawer header */}
            <div className="sticky top-0 z-10 flex items-center justify-between px-6 py-4
                            bg-[var(--surface-raised,#fff)] border-b border-[var(--border-default,#DCE0E2)]">
              <div className="flex items-center gap-2">
                <Smartphone className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
                {editingName ? (
                  <div className="flex items-center gap-2">
                    <input
                      type="text"
                      value={nameInput}
                      onChange={(e) => setNameInput(e.target.value)}
                      onKeyDown={(e) => { if (e.key === 'Enter') submitRename(); if (e.key === 'Escape') setEditingName(false); }}
                      className="text-base font-semibold text-[var(--text-primary,#1B3139)] bg-transparent
                                 border-b-2 border-[var(--border-focus,#2272B4)] outline-none px-0 py-0 w-48"
                      autoFocus
                      disabled={renaming}
                    />
                    <button onClick={submitRename} disabled={renaming} className="p-1 rounded hover:bg-[var(--surface-tertiary,#EEEDE9)]">
                      <Check className="w-4 h-4 text-[var(--accent-success,#00A972)]" />
                    </button>
                  </div>
                ) : (
                  <div className="flex items-center gap-2">
                    <h2 className="text-base font-semibold text-[var(--text-primary,#1B3139)]">
                      {selectedDevice.label}
                    </h2>
                    {selectedDevice.is_mine && (
                      <button onClick={startRename} className="p-1 rounded hover:bg-[var(--surface-tertiary,#EEEDE9)]" title="Rename device">
                        <Pencil className="w-3.5 h-3.5 text-[var(--text-secondary,#5A6F77)]" />
                      </button>
                    )}
                  </div>
                )}
              </div>
              <button onClick={closeDetail} className="p-1.5 rounded-lg hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100">
                <X className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
              </button>
            </div>

            {/* Drawer body */}
            <div className="px-6 py-5 space-y-6">
              {/* Device info */}
              <div className="space-y-2 text-sm text-[var(--text-secondary,#5A6F77)]">
                {selectedDevice.username && (
                  <div className="flex items-center gap-2">
                    <User className="w-4 h-4" />
                    <span>{selectedDevice.username}</span>
                  </div>
                )}
                {selectedDevice.revoked_at && (
                  <div className="flex items-center gap-2 px-3 py-2 rounded-lg
                                  bg-[var(--accent-error,#BD2B26)]/5 border border-[var(--accent-error,#BD2B26)]/20">
                    <ShieldOff className="w-4 h-4 text-[var(--accent-error,#BD2B26)]" />
                    <span className="text-sm font-medium text-[var(--accent-error,#BD2B26)]">
                      Revoked {timeAgo(selectedDevice.revoked_at)}
                    </span>
                  </div>
                )}
                <p>Paired: {new Date(selectedDevice.paired_at).toLocaleDateString()}</p>
                <p>Last seen: {selectedDevice.last_seen_at ? new Date(selectedDevice.last_seen_at).toLocaleString() : 'Never'}</p>
                <div className="flex items-center gap-2">
                  <span>Expires: {new Date(selectedDevice.expires_at).toLocaleDateString()}</span>
                  {selectedDevice.is_mine && !selectedDevice.revoked_at && (
                    <button
                      type="button"
                      onClick={() => handleExtend(7)}
                      disabled={extending}
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium
                                 text-[var(--accent-info,#2272B4)] bg-[var(--accent-info,#2272B4)]/10
                                 hover:bg-[var(--accent-info,#2272B4)]/20 transition-colors duration-100
                                 disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      <Clock className="w-3 h-3" />
                      {extending ? 'Extending...' : '+7 days'}
                    </button>
                  )}
                </div>
                {isExpired(selectedDevice.expires_at) && !selectedDevice.revoked_at && selectedDevice.is_mine && (
                  <p className="text-xs text-[var(--accent-error,#BD2B26)] font-medium mt-1">
                    This device has expired. Extend to re-activate.
                  </p>
                )}
              </div>


              {/* Re-pair */}
              {selectedDevice.is_mine && (
                <div className="space-y-3">
                  {!repairQrData ? (
                    <button
                      type="button"
                      onClick={handleRepair}
                      disabled={repairing}
                      className="inline-flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium
                                 text-[var(--text-primary,#1B3139)] bg-[var(--surface-tertiary,#EEEDE9)]
                                 hover:bg-[var(--surface-secondary,#F5F4F0)] border border-[var(--border-default,#DCE0E2)]
                                 transition-colors duration-100
                                 disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      <RefreshCw className={`w-4 h-4 ${repairing ? 'animate-spin' : ''}`} />
                      {repairing ? 'Generating QR...' : 'Re-pair device'}
                    </button>
                  ) : (
                    <div className="flex flex-col items-center gap-3 p-4 rounded-xl border border-[var(--border-default,#DCE0E2)] bg-[var(--surface-secondary,#F5F4F0)]">
                      <p className="text-sm font-medium text-[var(--text-primary,#1B3139)]">Scan to re-pair</p>
                      <div className="p-3 bg-white rounded-lg">
                        <QRCodeSVG value={repairQrData} size={180} level="M" />
                      </div>
                      <p className="text-xs text-[var(--text-secondary,#5A6F77)] text-center">
                        Open lakeLoom on the device and scan this code to re-activate pairing.
                      </p>
                      <button
                        type="button"
                        onClick={() => setRepairQrData(null)}
                        className="text-xs text-[var(--text-secondary,#5A6F77)] hover:text-[var(--text-primary,#1B3139)] underline"
                      >
                        Dismiss
                      </button>
                    </div>
                  )}
                </div>
              )}

              {/* Stats */}
              {statsLoading ? (
                <div className="space-y-3">
                  <Skeleton className="h-16 rounded-lg" />
                  <Skeleton className="h-16 rounded-lg" />
                  <Skeleton className="h-16 rounded-lg" />
                </div>
              ) : deviceStats ? (
                <div className="space-y-4">
                  <h3 className="text-sm font-medium text-[var(--text-primary,#1B3139)]">Activity</h3>

                  {/* Stat cards */}
                  <div className="grid grid-cols-2 gap-3">
                    <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                      <div className="flex items-center gap-2 mb-1">
                        <FolderOpen className="w-4 h-4 text-[var(--accent-primary,#FF3621)]" />
                        <span className="text-xs text-[var(--text-secondary,#5A6F77)]">Projects</span>
                      </div>
                      <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{deviceStats.project_count}</p>
                    </div>
                    <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                      <div className="flex items-center gap-2 mb-1">
                        <Upload className="w-4 h-4 text-[var(--accent-info,#2272B4)]" />
                        <span className="text-xs text-[var(--text-secondary,#5A6F77)]">Uploads</span>
                      </div>
                      <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{deviceStats.upload_count}</p>
                    </div>
                    <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                      <div className="flex items-center gap-2 mb-1">
                        <Video className="w-4 h-4 text-[var(--accent-success,#00A972)]" />
                        <span className="text-xs text-[var(--text-secondary,#5A6F77)]">Captures</span>
                      </div>
                      <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{deviceStats.capture_count}</p>
                    </div>
                    <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                      <div className="flex items-center gap-2 mb-1">
                        <span className="text-xs text-[var(--text-secondary,#5A6F77)]">Completed</span>
                      </div>
                      <p className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">{deviceStats.captures.completed}</p>
                    </div>
                  </div>

                  {/* Upload kinds */}
                  {Object.keys(deviceStats.upload_kinds).length > 0 && (
                    <div>
                      <h4 className="text-xs font-medium text-[var(--text-secondary,#5A6F77)] mb-2 uppercase tracking-wide">Upload Types</h4>
                      <div className="flex flex-wrap gap-2">
                        {Object.entries(deviceStats.upload_kinds).map(([kind, count]) => (
                          <span key={kind} className="inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs
                                                     bg-[var(--surface-tertiary,#EEEDE9)] text-[var(--text-primary,#1B3139)]">
                            {kind} <span className="font-medium">{count}</span>
                          </span>
                        ))}
                      </div>
                    </div>
                  )}

                  {/* Most recent project */}
                  {deviceStats.most_recent_project && (
                    <div>
                      <h4 className="text-xs font-medium text-[var(--text-secondary,#5A6F77)] mb-2 uppercase tracking-wide">Most Recent Project</h4>
                      <div className="rounded-lg border border-[var(--border-default,#DCE0E2)] p-3">
                        <p className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
                          {deviceStats.most_recent_project.name}
                        </p>
                        <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-1">
                          Assigned {timeAgo(deviceStats.most_recent_project.assigned_at)}
                        </p>
                      </div>
                    </div>
                  )}

                  {/* No activity */}
                  {deviceStats.project_count === 0 && deviceStats.upload_count === 0 && deviceStats.capture_count === 0 && (
                    <p className="text-sm text-[var(--text-secondary,#5A6F77)] italic">
                      No activity recorded for this device yet.
                    </p>
                  )}
                </div>
              ) : null}

              {/* Revoke button in drawer */}
              {selectedDevice.is_mine && !selectedDevice.revoked_at && (
                <div className="pt-4 border-t border-[var(--border-default,#DCE0E2)]">
                  <button
                    type="button"
                    onClick={() => setRevokeTarget(selectedDevice)}
                    className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium
                               text-[var(--accent-error,#BD2B26)] border border-[var(--accent-error,#BD2B26)]/30
                               hover:bg-[var(--accent-error,#BD2B26)]/5 transition-colors duration-100"
                  >
                    <Trash2 className="w-4 h-4" />
                    Revoke device
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Pair device modal */}
      <PairDeviceModal open={pairModalOpen} onClose={() => { setPairModalOpen(false); fetchDevices(); }} />

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
