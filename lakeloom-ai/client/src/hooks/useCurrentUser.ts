import { useState, useEffect } from 'react';

interface CurrentUser {
  email: string | null;
  displayName: string;
  scimId: string | null;
}

interface UseCurrentUserResult {
  user: CurrentUser | null;
  isLoading: boolean;
}

/**
 * Fetches and caches the current user's identity from GET /api/me.
 * The auth sidecar injects identity headers for browser sessions.
 * Call once at the app shell level — the result is stable for the session.
 */
export function useCurrentUser(): UseCurrentUserResult {
  const [user, setUser] = useState<CurrentUser | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    fetch('/api/me')
      .then((res) => {
        if (!res.ok) throw new Error(`/api/me returned ${res.status}`);
        return res.json();
      })
      .then((data) => {
        if (!cancelled) {
          setUser({
            email: data.email,
            displayName: data.display_name,
            scimId: data.scim_id,
          });
        }
      })
      .catch((err) => {
        console.warn('[useCurrentUser] Failed to fetch identity:', err);
      })
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });

    return () => { cancelled = true; };
  }, []);

  return { user, isLoading };
}
