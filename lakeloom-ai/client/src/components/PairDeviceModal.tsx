/**
 * PairDeviceModal — inline device selector + QR code pairing.
 *
 * Shown from ProjectDetailPage when user clicks "Pair iPhone" CTA.
 * Keeps user in context (no page navigation) while offering:
 *   1. Already-paired devices (shows device label, last seen, select button)
 *   2. New pairing QR code (auto-refreshes every 30s, SSE for instant confirmation)
 *
 * Fires onDeviceSelected(deviceId) when a device is chosen, so the parent
 * can associate the device with the project context.
 *
 * Brand: Databricks semantic tokens, DM Sans, motion vars, WCAG AA.
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { X, Smartphone, Loader2, CheckCircle2 } from 'lucide-react';

// ── Types ────────────────────────────────────────────────────────────────────

interface PairedDevice {
  id: string;
  label: string;
  first_seen_at: string;
  last_seen_at: string;
  expires_at: string;
}

interface QRPayload {
  v: number;
  session: { token: string; expires_at: string };
  [key: string]: unknown;
}

export interface PairDeviceModalProps {
  open: boolean;
  onClose: () => void;
  onDeviceSelected?: (deviceId: string, deviceLabel: string) => void;
  /** The paired_session_id of the device currently assigned to this project */
  activeDeviceId?: string | null;
}

// ── Component ────────────────────────────────────────────────────────────────

export function PairDeviceModal({ open, onClose, onDeviceSelected, activeDeviceId }: PairDeviceModalProps) {
  const [devices, setDevices] = useState<PairedDevice[]>([]);
  const [loadingDevices, setLoadingDevices] = useState(true);
  const [qrDataUrl, setQrDataUrl] = useState<string>('');
  const [qrLoading, setQrLoading] = useState(true);
  const [qrError, setQrError] = useState<string | null>(null);
  const [justPaired, setJustPaired] = useState<{ label: string; id: string } | null>(null);

  const refreshTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const eventSourceRef = useRef<EventSource | null>(null);

  // ── Fetch paired devices ──────────────────────────────────────────────
  const fetchDevices = useCallback(async () => {
    try {
      setLoadingDevices(true);
      const res = await fetch('/api/pairing/devices');
      if (res.ok) {
        const data = await res.json();
        setDevices(data.devices ?? []);
      }
    } catch {
      // Non-critical
    } finally {
      setLoadingDevices(false);
    }
  }, []);

  // ── Fetch QR payload ──────────────────────────────────────────────────
  const fetchQR = useCallback(async () => {
    try {
      setQrLoading(true);
      setQrError(null);
      const res = await fetch('/api/pairing/qr');
      if (res.status === 503) {
        setQrError('Pairing not configured. Ask your admin to provision the Xcode SPN.');
        return;
      }
      if (!res.ok) {
        setQrError(`Server error: ${res.status}`);
        return;
      }
      const payload: QRPayload = await res.json();
      setQrDataUrl(`data:application/json;base64,${btoa(JSON.stringify(payload))}`);
    } catch (err) {
      setQrError((err as Error).message);
    } finally {
      setQrLoading(false);
    }
  }, []);

  // ── Lifecycle: open/close ──────────────────────────────────────────────
  useEffect(() => {
    if (!open) {
      // Cleanup on close
      if (refreshTimerRef.current) clearInterval(refreshTimerRef.current);
      if (eventSourceRef.current) eventSourceRef.current.close();
      setJustPaired(null);
      return;
    }

    // Fetch data on open
    fetchDevices();
    fetchQR();

    // QR rotation every 30s
    refreshTimerRef.current = setInterval(fetchQR, 30_000);

    // SSE for real-time pairing confirmation
    const es = new EventSource('/api/pairing/events');
    eventSourceRef.current = es;
    es.addEventListener('device_paired', (event) => {
      const data = JSON.parse(event.data);
      setJustPaired({ label: data.device_label, id: data.paired_session_id });
      fetchDevices(); // Refresh device list
    });

    return () => {
      if (refreshTimerRef.current) clearInterval(refreshTimerRef.current);
      es.close();
    };
  }, [open, fetchDevices, fetchQR]);

  // ── Render ──────────────────────────────────────────────────────────────
  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/40 backdrop-blur-sm"
        onClick={onClose}
      />

      {/* Modal */}
      <div
        className="relative w-full max-w-lg max-h-[85vh] overflow-y-auto mx-4
                   bg-[var(--surface-raised,#fff)] rounded-2xl shadow-2xl
                   border border-[var(--border-default,#DCE0E2)]"
      >
        {/* Header */}
        <div className="sticky top-0 z-10 flex items-center justify-between px-6 py-4
                        bg-[var(--surface-raised,#fff)] border-b border-[var(--border-default,#DCE0E2)]
                        rounded-t-2xl">
          <div className="flex items-center gap-2">
            <Smartphone className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
            <h2 className="text-lg font-semibold text-[var(--text-primary,#1B3139)]">
              Connect Device
            </h2>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg hover:bg-[var(--surface-tertiary,#EEEDE9)] transition-colors duration-100"
          >
            <X className="w-5 h-5 text-[var(--text-secondary,#5A6F77)]" />
          </button>
        </div>

        <div className="px-6 py-5 space-y-6">
          {/* ── Just paired success banner ─────────────────────────────── */}
          {justPaired && (
            <div className="flex items-center gap-3 px-4 py-3 rounded-xl
                            bg-[var(--accent-success-subtle,#dcfce7)] border border-[var(--accent-success,#00A972)]/20">
              <CheckCircle2 className="w-5 h-5 text-[var(--accent-success,#00A972)] flex-shrink-0" />
              <div>
                <p className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
                  {justPaired.label} paired successfully
                </p>
                <p className="text-xs text-[var(--text-secondary,#5A6F77)]">
                  Ready to capture. You can select it below.
                </p>
              </div>
            </div>
          )}

          {/* ── Section 1: Paired devices ──────────────────────────────── */}
          {!loadingDevices && devices.length > 0 && (
            <div>
              <h3 className="text-sm font-medium text-[var(--text-primary,#1B3139)] mb-3">
                Your Paired Devices
              </h3>
              <div className="space-y-2">
                {devices.map((device) => (
                  <div
                    key={device.id}
                    className={`flex items-center justify-between px-4 py-3 rounded-xl
                               border transition-all duration-150 cursor-pointer group
                               ${device.id === activeDeviceId
                                 ? 'border-[var(--accent-success,#00A972)]/40 bg-[var(--accent-success-subtle,#dcfce7)]/50'
                                 : 'border-[var(--border-default,#DCE0E2)] hover:border-[var(--border-focus,#2272B4)] hover:shadow-sm'
                               }`}
                    onClick={() => {
                      onDeviceSelected?.(device.id, device.label);
                      onClose();
                    }}
                  >
                    <div className="flex items-center gap-3">
                      <div className={`w-9 h-9 rounded-lg flex items-center justify-center transition-colors duration-150
                                      ${device.id === activeDeviceId
                                        ? 'bg-[var(--accent-success,#00A972)]/10'
                                        : 'bg-[var(--surface-tertiary,#EEEDE9)] group-hover:bg-[var(--accent-primary,#FF3621)]/10'
                                      }`}>
                        <Smartphone className={`w-4 h-4 transition-colors duration-150
                                               ${device.id === activeDeviceId
                                                 ? 'text-[var(--accent-success,#00A972)]'
                                                 : 'text-[var(--text-secondary,#5A6F77)] group-hover:text-[var(--accent-primary,#FF3621)]'
                                               }`} />
                      </div>
                      <div>
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-[var(--text-primary,#1B3139)]">
                            {device.label}
                          </p>
                          {device.id === activeDeviceId && (
                            <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full text-[10px] font-medium
                                           bg-[var(--accent-success,#00A972)]/15 text-[var(--accent-success,#00A972)]">
                              <span className="w-1.5 h-1.5 rounded-full bg-[var(--accent-success,#00A972)] animate-pulse" />
                              Active
                            </span>
                          )}
                        </div>
                        <p className="text-xs text-[var(--text-secondary,#5A6F77)]">
                          Last active: {device.last_seen_at
                            ? new Date(device.last_seen_at).toLocaleDateString()
                            : 'Never'}
                          {' \u00b7 '}
                          Expires: {new Date(device.expires_at).toLocaleDateString()}
                        </p>
                      </div>
                    </div>
                    <span className={`text-xs font-medium transition-opacity duration-150
                                     ${device.id === activeDeviceId
                                       ? 'text-[var(--accent-success,#00A972)] opacity-100'
                                       : 'text-[var(--accent-primary,#FF3621)] opacity-0 group-hover:opacity-100'
                                     }`}>
                      {device.id === activeDeviceId ? 'Active' : 'Select'}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* ── Section 2: QR Code for new pairing ─────────────────────── */}
          <div>
            <h3 className="text-sm font-medium text-[var(--text-primary,#1B3139)] mb-3">
              {devices.length > 0 ? 'Or pair a new device' : 'Pair your iPhone'}
            </h3>
            <div className="rounded-xl border border-[var(--border-default,#DCE0E2)]
                            bg-[var(--surface-primary,#1B3139)] p-6">
              {qrLoading && (
                <div className="flex items-center justify-center h-48">
                  <Loader2 className="w-6 h-6 animate-spin text-white/60" />
                </div>
              )}

              {!qrLoading && qrError && (
                <div className="text-center py-8">
                  <p className="text-sm text-white/70">{qrError}</p>
                  <button
                    onClick={fetchQR}
                    className="mt-3 text-sm text-white underline underline-offset-4 hover:text-white/80"
                  >
                    Retry
                  </button>
                </div>
              )}

              {!qrLoading && !qrError && qrDataUrl && (
                <div className="flex flex-col items-center gap-3">
                  <div className="bg-white p-3 rounded-lg">
                    <QRCodeSVG
                      value={qrDataUrl}
                      size={200}
                      level="M"
                      marginSize={2}
                    />
                  </div>
                  <p className="text-xs text-white/50">
                    Scan with your iPhone camera
                  </p>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
