import { useCallback, useRef, useState } from 'react';

// ── Types ─────────────────────────────────────────────────────────────────────

export interface UploadResponse {
  id: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  sha256_hex: string;
  uploaded_at: string;
}

export interface UploadItem {
  /** Client-generated unique ID */
  id: string;
  file: File;
  status: 'queued' | 'uploading' | 'success' | 'error';
  /** Upload progress 0–100 */
  progress: number;
  response?: UploadResponse;
  error?: string;
  /** Abort this upload */
  abort: () => void;
}

export interface UseUploadOptions {
  /**
   * Same-origin relative API path for uploads.
   * Example: "/api/captures/abc-123/screenshots"
   * Must start with "/api/" — only lakeLoom's own backend is targeted.
   */
  url: string;
  /** Max concurrent uploads (default: 3) */
  concurrency?: number;
  onSuccess?: (response: UploadResponse, file: File) => void;
  onError?: (error: string, file: File) => void;
  onAllComplete?: () => void;
}

// ── Hook ──────────────────────────────────────────────────────────────────────

/**
 * Manages a concurrent upload queue to the lakeLoom backend API.
 * Uses XMLHttpRequest for upload progress tracking (fetch lacks this).
 *
 * Design:
 * - Parallel uploads capped at `concurrency` (default 3)
 * - Per-file progress, cancel, and retry
 * - Same-origin only — sends to /api/* paths on this App
 */
export function useUpload(options: UseUploadOptions) {
  const { url, concurrency = 3, onSuccess, onError, onAllComplete } = options;

  const [items, setItems] = useState<UploadItem[]>([]);
  const activeCount = useRef(0);
  const xhrMap = useRef<Map<string, XMLHttpRequest>>(new Map());

  // Stable refs for callbacks to avoid stale closures
  const onSuccessRef = useRef(onSuccess);
  const onErrorRef = useRef(onError);
  const onAllCompleteRef = useRef(onAllComplete);
  onSuccessRef.current = onSuccess;
  onErrorRef.current = onError;
  onAllCompleteRef.current = onAllComplete;

  // ── Helpers ───────────────────────────────────────────────────────────────

  const genId = () => crypto.randomUUID();

  const updateItem = (id: string, patch: Partial<UploadItem>) => {
    setItems((prev) => prev.map((item) => (item.id === id ? { ...item, ...patch } : item)));
  };

  // ── Queue drain ───────────────────────────────────────────────────────────

  const drainQueue = useCallback(() => {
    setItems((prev) => {
      const queued = prev.filter((i) => i.status === 'queued');
      const slotsAvailable = concurrency - activeCount.current;

      if (slotsAvailable <= 0 || queued.length === 0) {
        // Check if everything is done
        const anyPending = prev.some((i) => i.status === 'queued' || i.status === 'uploading');
        if (!anyPending && prev.length > 0) {
          setTimeout(() => onAllCompleteRef.current?.(), 0);
        }
        return prev;
      }

      const toStart = queued.slice(0, slotsAvailable);
      // Mark them as uploading synchronously so they won't be double-started
      const updated = prev.map((item) =>
        toStart.some((s) => s.id === item.id) ? { ...item, status: 'uploading' as const } : item,
      );

      // Kick off XHRs after state commits
      setTimeout(() => {
        for (const item of toStart) {
          doStartUpload(item);
        }
      }, 0);

      return updated;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [concurrency]);

  // ── Core upload logic ─────────────────────────────────────────────────────

  function doStartUpload(item: UploadItem) {
    activeCount.current++;

    const xhr = new XMLHttpRequest();
    xhrMap.current.set(item.id, xhr);

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) {
        const pct = Math.round((e.loaded / e.total) * 100);
        updateItem(item.id, { progress: pct });
      }
    };

    xhr.onload = () => {
      xhrMap.current.delete(item.id);
      activeCount.current--;

      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          const response: UploadResponse = JSON.parse(xhr.responseText);
          updateItem(item.id, { status: 'success', progress: 100, response });
          onSuccessRef.current?.(response, item.file);
        } catch {
          updateItem(item.id, { status: 'error', error: 'Invalid server response' });
          onErrorRef.current?.('Invalid server response', item.file);
        }
      } else {
        let msg = `Upload failed (${xhr.status})`;
        try {
          const body = JSON.parse(xhr.responseText);
          if (body.error) msg = body.error;
        } catch { /* use default */ }
        updateItem(item.id, { status: 'error', error: msg });
        onErrorRef.current?.(msg, item.file);
      }

      drainQueue();
    };

    xhr.onerror = () => {
      xhrMap.current.delete(item.id);
      activeCount.current--;
      updateItem(item.id, { status: 'error', error: 'Network error' });
      onErrorRef.current?.('Network error', item.file);
      drainQueue();
    };

    xhr.onabort = () => {
      xhrMap.current.delete(item.id);
      activeCount.current--;
      setItems((prev) => prev.filter((i) => i.id !== item.id));
      drainQueue();
    };

    const formData = new FormData();
    formData.append('file', item.file);

    // Same-origin POST to lakeLoom backend (e.g. /api/captures/:id/screenshots)
    xhr.open('POST', url);
    xhr.send(formData);
  }

  // ── Public API ────────────────────────────────────────────────────────────

  const upload = useCallback(
    (files: File[]) => {
      const newItems: UploadItem[] = files.map((file) => ({
        id: genId(),
        file,
        status: 'queued' as const,
        progress: 0,
        abort: () => {},
      }));

      setItems((prev) => [...prev, ...newItems]);
      setTimeout(() => drainQueue(), 0);
    },
    [drainQueue],
  );

  const retry = useCallback(
    (itemId: string) => {
      setItems((prev) =>
        prev.map((i) =>
          i.id === itemId && i.status === 'error'
            ? { ...i, status: 'queued' as const, progress: 0, error: undefined }
            : i,
        ),
      );
      setTimeout(() => drainQueue(), 0);
    },
    [drainQueue],
  );

  const cancel = useCallback((itemId: string) => {
    const xhr = xhrMap.current.get(itemId);
    if (xhr) {
      xhr.abort();
    } else {
      setItems((prev) => prev.filter((i) => i.id !== itemId));
    }
  }, []);

  const cancelAll = useCallback(() => {
    for (const xhr of xhrMap.current.values()) {
      xhr.abort();
    }
    xhrMap.current.clear();
    activeCount.current = 0;
    setItems([]);
  }, []);

  const clearCompleted = useCallback(() => {
    setItems((prev) => prev.filter((i) => i.status !== 'success'));
  }, []);

  return {
    items,
    upload,
    retry,
    cancel,
    cancelAll,
    clearCompleted,
    activeCount: activeCount.current,
  };
}
