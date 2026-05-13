/**
 * PairingPage — QR code display + device management for iPhone pairing.
 *
 * States:
 *   1. Loading — fetching QR payload from /api/pairing/qr
 *   2. QR Display — renders QR code, rotates every 30s, SSE listens for pairing
 *   3. Paired — device confirmed, shows success + device info
 *   4. Error/Gated — SPN not provisioned (503), shows admin onboarding panel
 *
 * Also includes inline device list with revoke capability.
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from '@databricks/appkit-ui/react';
import { QRCodeSVG } from 'qrcode.react';

// ── Types ────────────────────────────────────────────────────────────────────

interface QRPayload {
  v: number;
  workspace: { url: string; id: string; name: string; cloud: string };
  user: { scim_id: string; user_name: string; display_name: string };
  xcode_spn: { client_id: string; client_secret: string };
  session: { token: string; expires_at: string };
  app: { base_url: string };
}

interface PairedDevice {
  id: string;
  label: string;
  first_seen_at: string;
  last_seen_at: string;
  expires_at: string;
  paired_at: string;
}

interface ProblemDetails {
  type: string;
  title: string;
  status: number;
  detail: string;
  missing?: string[];
}

type PageState =
  | { kind: 'loading' }
  | { kind: 'qr'; payload: QRPayload; qrDataUrl: string }
  | { kind: 'paired'; deviceLabel: string; deviceId: string }
  | { kind: 'gated'; problem: ProblemDetails }
  | { kind: 'error'; message: string };

// ── QR encoding (simple SVG via canvas-free approach) ─────────────────────────
// We encode the payload as gzipped base64url JSON in a QR.
// For the browser we render the raw JSON as a data URL placeholder.
function encodeQRPayload(payload: QRPayload): string {
  // Placeholder: return a data URL that represents the payload.
  // Real implementation will gzip + base64url encode, then generate QR SVG.
  return `data:application/json;base64,${btoa(JSON.stringify(payload))}`;
}

// ── Component ────────────────────────────────────────────────────────────────

export function PairingPage() {
  const [state, setState] = useState<PageState>({ kind: 'loading' });
  const [devices, setDevices] = useState<PairedDevice[]>([]);
  const eventSourceRef = useRef<EventSource | null>(null);
  const refreshTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Fetch QR payload ─────────────────────────────────────────────────────
  const fetchQR = useCallback(async () => {
    try {
      const res = await fetch('/api/pairing/qr');
      if (res.status === 503) {
        const problem: ProblemDetails = await res.json();
        setState({ kind: 'gated', problem });
        return;
      }
      if (!res.ok) {
        setState({ kind: 'error', message: `Server error: ${res.status}` });
        return;
      }
      const payload: QRPayload = await res.json();
      const qrDataUrl = encodeQRPayload(payload);
      setState({ kind: 'qr', payload, qrDataUrl });
    } catch (err) {
      setState({ kind: 'error', message: (err as Error).message });
    }
  }, []);

  // ── Fetch paired devices ─────────────────────────────────────────────────
  const fetchDevices = useCallback(async () => {
    try {
      const res = await fetch('/api/pairing/devices');
      if (res.ok) {
        const data = await res.json();
        setDevices(data.devices ?? []);
      }
    } catch {
      // Non-critical — devices list is informational
    }
  }, []);

  // ── Revoke device ────────────────────────────────────────────────────────
  const revokeDevice = async (deviceId: string) => {
    if (!confirm('Revoke this device? It will need to re-pair to access lakeLoom.')) return;
    await fetch(`/api/pairing/devices/${deviceId}`, { method: 'DELETE' });
    setDevices((prev) => prev.filter((d) => d.id !== deviceId));
  };

  // ── Setup SSE + polling ──────────────────────────────────────────────────
  useEffect(() => {
    fetchQR();
    fetchDevices();

    // QR rotation every 30s
    refreshTimerRef.current = setInterval(fetchQR, 30_000);

    // SSE for real-time pairing confirmation
    const es = new EventSource('/api/pairing/events');
    eventSourceRef.current = es;

    es.addEventListener('device_paired', (event) => {
      const data = JSON.parse(event.data);
      setState({ kind: 'paired', deviceLabel: data.device_label, deviceId: data.device_id });
      fetchDevices();
    });

    return () => {
      if (refreshTimerRef.current) clearInterval(refreshTimerRef.current);
      es.close();
    };
  }, [fetchQR, fetchDevices]);

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <div className="max-w-3xl mx-auto space-y-6 mt-8">
      <h2 className="text-2xl font-bold text-foreground">Pair iPhone</h2>
      <p className="text-muted-foreground">
        Scan the QR code below with your iPhone to pair it with this workspace.
      </p>

      {/* QR / Status card */}
      <Card className="shadow-lg">
        <CardHeader>
          <CardTitle>
            {state.kind === 'paired' ? 'Device Paired' : 'QR Code'}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.kind === 'loading' && (
            <div className="flex items-center justify-center h-64">
              <p className="text-muted-foreground animate-pulse">Loading pairing session...</p>
            </div>
          )}

          {state.kind === 'qr' && (
            <div className="flex flex-col items-center gap-4">
              <div className="bg-white p-4 rounded-lg">
                <QRCodeSVG
                  value={state.qrDataUrl}
                  size={256}
                  level="M"
                  marginSize={2}
                />
              </div>
              <p className="text-xs text-muted-foreground">
                Refreshes automatically every 30 seconds
              </p>
            </div>
          )}

          {state.kind === 'paired' && (
            <div className="flex flex-col items-center gap-3 py-8">
              <div className="w-16 h-16 rounded-full bg-green-100 dark:bg-green-900/30 flex items-center justify-center">
                <span className="text-2xl">✓</span>
              </div>
              <p className="text-lg font-medium text-foreground">{state.deviceLabel}</p>
              <p className="text-sm text-muted-foreground">
                Successfully paired. You can close this page.
              </p>
            </div>
          )}

          {state.kind === 'gated' && (
            <div className="space-y-3 py-4">
              <p className="font-medium text-destructive">{state.problem.title}</p>
              <p className="text-sm text-muted-foreground">{state.problem.detail}</p>
              {state.problem.missing && (
                <ul className="list-disc list-inside text-sm text-muted-foreground">
                  {state.problem.missing.map((key) => (
                    <li key={key}>{key}</li>
                  ))}
                </ul>
              )}
            </div>
          )}

          {state.kind === 'error' && (
            <div className="py-4">
              <p className="text-sm text-destructive">{state.message}</p>
              <button
                onClick={fetchQR}
                className="mt-3 text-sm text-primary underline underline-offset-4"
              >
                Retry
              </button>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Paired devices */}
      {devices.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Paired Devices</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {devices.map((device) => (
                <div key={device.id} className="flex items-center justify-between py-2 border-b last:border-0">
                  <div>
                    <p className="font-medium text-sm">{device.label}</p>
                    <p className="text-xs text-muted-foreground">
                      Last active: {device.last_seen_at ? new Date(device.last_seen_at).toLocaleDateString() : 'Never'}
                      {' · '}
                      Expires: {new Date(device.expires_at).toLocaleDateString()}
                    </p>
                  </div>
                  <button
                    onClick={() => revokeDevice(device.id)}
                    className="text-xs text-destructive hover:underline"
                  >
                    Revoke
                  </button>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
