import { describe, expect, it } from 'vitest';
import { parseAccountingSnapshot } from '@/data/accountingReview';

const org = 'fb100000-0000-4000-8000-000000000001';
const snapshot = { organizationId: org, periodStart: '2025-01-06', scope: 'self', source: 'locked-original-ph-v4', employeeCount: 1, workedSeconds: '32400.125', overtimeSeconds: '3600.125', lines: [{ code: 'RH_ND', seconds: '25200' }, { code: 'RH', seconds: '3600' }, { code: 'RH_OT', seconds: '3600.125' }] };

describe('server accounting review contract', () => {
  it('accepts only validated locked original snapshot totals', () => {
    expect(parseAccountingSnapshot(snapshot, org, '2025-01-06', 'self').workedSeconds).toBe('32400.125');
  });
  it('rejects scope, tenant and period mismatch', () => {
    expect(() => parseAccountingSnapshot(snapshot, org, '2025-01-06', 'organization')).toThrow();
    expect(() => parseAccountingSnapshot(snapshot, 'other', '2025-01-06', 'self')).toThrow();
    expect(() => parseAccountingSnapshot(snapshot, org, '2025-01-13', 'self')).toThrow();
  });
  it('rejects invalid server quantities and pay codes', () => {
    expect(() => parseAccountingSnapshot({ ...snapshot, workedSeconds: '-1' }, org, '2025-01-06', 'self')).toThrow();
    expect(() => parseAccountingSnapshot({ ...snapshot, lines: [{ code: 'fake', seconds: '999' }] }, org, '2025-01-06', 'self')).toThrow();
  });
});
