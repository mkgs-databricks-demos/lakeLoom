/**
 * SQL warehouse query service — executes statements against Unity Catalog
 * tables via the Databricks SQL Statement Execution REST API.
 *
 * Uses the App's auto-provisioned SPN credentials (DATABRICKS_HOST + token)
 * and the SQL warehouse ID from app.yaml (DATABRICKS_WAREHOUSE_ID).
 *
 * This is the bridge between the App backend (Node.js) and UC Delta tables
 * like transcript_events_raw that aren't in Lakebase.
 */

interface StatementResponse {
  statement_id: string;
  status: { state: 'SUCCEEDED' | 'FAILED' | 'RUNNING' | 'PENDING' | 'CANCELED' | 'CLOSED'; error?: { message: string } };
  manifest?: { schema: { columns: Array<{ name: string; type_name: string }> }; total_row_count: number };
  result?: { data_array: string[][] };
}

interface QueryResult {
  columns: string[];
  rows: Record<string, string | null>[];
  total_rows: number;
}

// ── Configuration ───────────────────────────────────────────────────────────

function getConfig() {
  const host = process.env.DATABRICKS_HOST ?? process.env.DATABRICKS_WORKSPACE_URL ?? '';
  const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID ?? '';
  const token = process.env.DATABRICKS_TOKEN ?? process.env.DATABRICKS_API_TOKEN ?? '';

  if (!host || !warehouseId) {
    throw new Error('[sql-service] Missing DATABRICKS_HOST or DATABRICKS_WAREHOUSE_ID');
  }

  // Normalize host to base URL
  const baseUrl = host.startsWith('http') ? host.replace(/\/$/, '') : `https://${host}`;
  return { baseUrl, warehouseId, token };
}

// ── Execute Statement ───────────────────────────────────────────────────────

/**
 * Execute a SQL statement against the configured warehouse.
 * Waits for completion (WAIT_TIMEOUT disposition) up to 50s.
 * For parameterized queries, pass params as { name, value, type? }[].
 */
export async function executeStatement(
  sql: string,
  params?: Array<{ name: string; value: string; type?: string }>,
): Promise<QueryResult> {
  const { baseUrl, warehouseId, token } = getConfig();

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
  };

  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

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
