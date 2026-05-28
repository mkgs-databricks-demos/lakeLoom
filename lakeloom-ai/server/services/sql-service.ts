/**
 * SQL warehouse query service — executes statements against Unity Catalog
 * tables via the Databricks SQL Statement Execution REST API.
 *
 * Auth strategy (in priority order):
 *   1. Caller-supplied OBO token (from x-forwarded-access-token header)
 *   2. DATABRICKS_TOKEN env var (App SPN, if configured)
 *
 * Uses DATABRICKS_HOST + DATABRICKS_WAREHOUSE_ID from the platform.
 */

interface StatementResponse {
  statement_id: string;
  status: { state: 'SUCCEEDED' | 'FAILED' | 'RUNNING' | 'PENDING' | 'CANCELED' | 'CLOSED'; error?: { message: string } };
  manifest?: { schema: { columns: Array<{ name: string; type_name: string }> }; total_row_count: number };
  result?: { data_array: string[][] };
}

export interface QueryResult {
  columns: string[];
  rows: Record<string, string | null>[];
  total_rows: number;
}

// ── Configuration ───────────────────────────────────────────────────────────────

function getConfig() {
  const host = process.env.DATABRICKS_HOST ?? process.env.DATABRICKS_WORKSPACE_URL ?? '';
  const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID ?? '';

  if (!host || !warehouseId) {
    throw new Error('[sql-service] Missing DATABRICKS_HOST or DATABRICKS_WAREHOUSE_ID');
  }

  // Normalize host to base URL
  const baseUrl = host.startsWith('http') ? host.replace(/\/$/, '') : `https://${host}`;
  return { baseUrl, warehouseId };
}

// ── Execute Statement ───────────────────────────────────────────────────────────

export interface ExecuteOptions {
  /** OBO access token from the user's browser session (x-forwarded-access-token) */
  accessToken?: string;
}

/**
 * Execute a SQL statement against the configured warehouse.
 * Waits for completion (WAIT_TIMEOUT disposition) up to 50s.
 *
 * @param sql - SQL statement (use :param_name for parameters)
 * @param params - Named parameters
 * @param options - Execution options (accessToken for OBO auth)
 */
export async function executeStatement(
  sql: string,
  params?: Array<{ name: string; value: string; type?: string }>,
  options?: ExecuteOptions,
): Promise<QueryResult> {
  const { baseUrl, warehouseId } = getConfig();

  // Resolve auth token: prefer caller-supplied OBO token, fallback to env var
  const token = options?.accessToken
    ?? process.env.DATABRICKS_TOKEN
    ?? process.env.DATABRICKS_API_TOKEN
    ?? '';

  if (!token) {
    throw new Error('[sql-service] No auth token available. Ensure x-forwarded-access-token header is present (browser session) or DATABRICKS_TOKEN is set.');
  }

  const body: Record<string, unknown> = {
    warehouse_id: warehouseId,
    statement: sql,
    wait_timeout: '50s',
    disposition: 'INLINE',
    format: 'JSON_ARRAY',
  };

  if (params && params.length > 0) {
    body.parameters = params.map((p) => ({
      name: p.name,
      value: p.value,
      type: p.type ?? 'STRING',
    }));
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${token}`,
  };

  const res = await fetch(`${baseUrl}/api/2.0/sql/statements/`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`[sql-service] Statement API ${res.status}: ${text}`);
  }

  const data = (await res.json()) as StatementResponse;

  if (data.status.state === 'FAILED') {
    throw new Error(`[sql-service] Query failed: ${data.status.error?.message ?? 'unknown'}`);
  }

  if (data.status.state !== 'SUCCEEDED') {
    throw new Error(`[sql-service] Unexpected state: ${data.status.state}`);
  }

  // Parse results
  const columns = data.manifest?.schema.columns.map((c) => c.name) ?? [];
  const rawRows = data.result?.data_array ?? [];

  const rows = rawRows.map((row) => {
    const obj: Record<string, string | null> = {};
    columns.forEach((col, i) => {
      obj[col] = row[i] ?? null;
    });
    return obj;
  });

  return {
    columns,
    rows,
    total_rows: data.manifest?.total_row_count ?? rows.length,
  };
}
