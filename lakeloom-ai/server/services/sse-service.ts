/**
 * Server-Sent Events (SSE) service for real-time pairing notifications.
 *
 * Manages open SSE connections per user_id. When a device confirms pairing,
 * the "device_paired" event is pushed to the user's browser session so the
 * QR page transitions to the success state.
 *
 * No external deps — Express supports SSE natively with res.write().
 */

import type { Response } from 'express';

// ── Connection registry ──────────────────────────────────────────────────────
// Map<userId, Set<Express Response objects with open SSE stream>>
const connections = new Map<string, Set<Response>>();

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Register a new SSE connection for a user.
 * Call from the GET /api/pairing/events handler after setting SSE headers.
 */
export function addConnection(userId: string, res: Response): void {
  if (!connections.has(userId)) {
    connections.set(userId, new Set());
  }
  connections.get(userId)!.add(res);

  // Clean up on disconnect
  res.on('close', () => {
    const userConns = connections.get(userId);
    if (userConns) {
      userConns.delete(res);
      if (userConns.size === 0) {
        connections.delete(userId);
      }
    }
  });
}

/**
 * Push an SSE event to all connections for a given user.
 *
 * @param userId - The user whose browser sessions should receive the event
 * @param event  - Event name (e.g., "device_paired")
 * @param data   - JSON-serializable payload
 */
export function pushEvent(userId: string, event: string, data: unknown): void {
  const userConns = connections.get(userId);
  if (!userConns || userConns.size === 0) return;

  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

  for (const res of userConns) {
    try {
      res.write(payload);
    } catch {
      // Connection may have been closed between check and write
      userConns.delete(res);
    }
  }
}

/**
 * Get the number of active connections for a user (for diagnostics).
 */
export function getConnectionCount(userId: string): number {
  return connections.get(userId)?.size ?? 0;
}

/**
 * Get total active SSE connections across all users.
 */
export function getTotalConnections(): number {
  let total = 0;
  for (const conns of connections.values()) {
    total += conns.size;
  }
  return total;
}
