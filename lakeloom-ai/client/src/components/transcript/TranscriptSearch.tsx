/**
 * TranscriptSearch — project-level full-text search across all capture transcripts.
 *
 * Renders a search bar with debounced input. Results appear as cards linking
 * to the CaptureDetailPage with the matching segment highlighted.
 *
 * Used in ProjectDetailPage to find specific spoken content across sessions.
 */

import { useState, useCallback, useRef } from 'react';
import { Link } from 'react-router';
import { Search, FileText, Loader2 } from 'lucide-react';

// ── Types ────────────────────────────────────────────────────────────────────

interface SearchResult {
  session_id: string;
  capture: { id: string; label: string; started_at: string } | null;
  event_id: string;
  event_time: string;
  text: string;
  segment_index: number | null;
}

interface SearchResponse {
  query: string;
  project_id: string;
  results: SearchResult[];
  total_results: number;
}

export interface TranscriptSearchProps {
  projectId: string;
}

// ── Component ────────────────────────────────────────────────────────────────

export function TranscriptSearch({ projectId }: TranscriptSearchProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const doSearch = useCallback(async (q: string) => {
    if (!q.trim()) {
      setResults([]);
      setSearched(false);
      return;
    }
    try {
      setLoading(true);
      const res = await fetch(`/api/projects/${projectId}/search?q=${encodeURIComponent(q.trim())}`);
      if (!res.ok) throw new Error(`Search failed: ${res.status}`);
      const data: SearchResponse = await res.json();
      setResults(data.results);
      setSearched(true);
    } catch {
      setResults([]);
    } finally {
      setLoading(false);
    }
  }, [projectId]);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const value = e.target.value;
    setQuery(value);

    // Debounce 400ms
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => doSearch(value), 400);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      if (debounceRef.current) clearTimeout(debounceRef.current);
      doSearch(query);
    }
  };

  // Highlight search term in text
  function highlightText(text: string, term: string): React.ReactNode {
    if (!term.trim()) return text;
    const regex = new RegExp(`(${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi');
    const parts = text.split(regex);
    return parts.map((part, i) =>
      regex.test(part) ? (
        <mark key={i} className="bg-[var(--accent-warning-subtle,#FFF3CD)] text-inherit rounded-sm px-0.5">
          {part}
        </mark>
      ) : (
        part
      ),
    );
  }

  return (
    <div className="space-y-3">
      {/* ── Search input ─────────────────────────────────────────── */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-[var(--text-secondary,#5A6F77)]" />
        <input
          type="text"
          value={query}
          onChange={handleChange}
          onKeyDown={handleKeyDown}
          placeholder="Search transcripts..."
          className="w-full pl-9 pr-4 py-2.5 rounded-lg border border-[var(--border-default,#DCE0E2)]
                     bg-[var(--surface-raised,#fff)] text-sm text-[var(--text-primary,#1B3139)]
                     placeholder:text-[var(--text-secondary,#5A6F77)]
                     focus:outline-none focus:ring-2 focus:ring-[var(--border-focus,#2272B4)]
                     transition-all duration-100"
        />
        {loading && (
          <Loader2 className="absolute right-3 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-[var(--text-secondary,#5A6F77)]" />
        )}
      </div>

      {/* ── Results ──────────────────────────────────────────────── */}
      {searched && results.length === 0 && (
        <p className="text-sm text-[var(--text-secondary,#5A6F77)] text-center py-4">
          No results found for &ldquo;{query}&rdquo;
        </p>
      )}

      {results.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs text-[var(--text-secondary,#5A6F77)]">
            {results.length} match{results.length !== 1 ? 'es' : ''} found
          </p>
          {results.map((result) => (
            <Link
              key={result.event_id}
              to={result.capture ? `/projects/${projectId}/captures/${result.capture.id}` : '#'}
              className="block px-4 py-3 rounded-lg border border-[var(--border-default,#DCE0E2)]
                         hover:border-[var(--border-focus,#2272B4)] hover:bg-[var(--surface-tertiary,#EEEDE9)]
                         transition-all duration-100"
            >
              <div className="flex items-start gap-3">
                <FileText className="w-4 h-4 text-[var(--text-secondary,#5A6F77)] flex-shrink-0 mt-0.5" />
                <div className="flex-1 min-w-0">
                  <p className="text-sm text-[var(--text-primary,#1B3139)] leading-relaxed">
                    {highlightText(result.text, query)}
                  </p>
                  <p className="text-xs text-[var(--text-secondary,#5A6F77)] mt-1">
                    {result.capture?.label ?? 'Unknown session'} &middot;{' '}
                    {new Date(result.event_time).toLocaleString()}
                  </p>
                </div>
              </div>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
