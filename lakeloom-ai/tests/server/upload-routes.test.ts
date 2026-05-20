import { describe, it, expect } from 'vitest';

import { __testables } from '../../server/routes/uploads/upload-routes';

describe('upload timestamp normalization', () => {
  it('uses client unix seconds when valid', () => {
    const result = __testables.normalizeClientTimestamp('1735689600');
    expect(result.source).toBe('client');
    expect(result.isoTimestamp).toBe('2025-01-01T00:00:00.000Z');
  });

  it('accepts unix seconds with fractional suffix by truncating to 10 digits', () => {
    const result = __testables.normalizeClientTimestamp('1735689600.987');
    expect(result.source).toBe('client');
    expect(result.isoTimestamp).toBe('2025-01-01T00:00:00.000Z');
  });

  it('falls back for fewer than 10 digits', () => {
    const result = __testables.normalizeClientTimestamp('173568960');
    expect(result.source).toBe('server');
    expect(result.fallbackReason).toBe('invalid_unix_seconds');
  });

  it('falls back for invalid unix seconds', () => {
    const result = __testables.normalizeClientTimestamp('2025-01-01T00:00:00Z');
    expect(result.source).toBe('server');
    expect(result.fallbackReason).toBe('invalid_unix_seconds');
  });

  it('falls back for missing timestamp', () => {
    const result = __testables.normalizeClientTimestamp(undefined);
    expect(result.source).toBe('server');
    expect(result.fallbackReason).toBe('missing_client_ts');
  });
});
