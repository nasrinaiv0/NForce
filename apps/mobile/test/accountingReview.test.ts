import { describe, expect, it } from 'vitest';
import { parseAccountingSnapshot } from '@/data/accountingReview';

const org = 'fb100000-0000-4000-8000-000000000001';
const snapshot = { organizationId: org, periodStart: '2025-01-06', scope: 'self', source: 'locked-original-v3', employeeCount: 1, workedMinutes: 540, approvedOvertimeMinutes: 60, lines: [{ code: 'RH_ND', minutes: 420 }, { code: 'RH', minutes: 60 }, { code: 'RH_OT', minutes: 60 }] };

describe('server accounting review contract', () => {
  it('accepts only validated locked original snapshot totals', () => {
    expect(parseAccountingSnapshot(snapshot, org, '2025-01-06', 'self').workedMinutes).toBe(540);
  });
  it('rejects scope, tenant and period mismatch', () => {
    expect(() => parseAccountingSnapshot(snapshot, org, '2025-01-06', 'organization')).toThrow();
    expect(() => parseAccountingSnapshot(snapshot, 'other', '2025-01-06', 'self')).toThrow();
    expect(() => parseAccountingSnapshot(snapshot, org, '2025-01-13', 'self')).toThrow();
  });
  it('rejects invalid server quantities and pay codes', () => {
    expect(() => parseAccountingSnapshot({ ...snapshot, workedMinutes: -1 }, org, '2025-01-06', 'self')).toThrow();
    expect(() => parseAccountingSnapshot({ ...snapshot, lines: [{ code: 'fake', minutes: 999 }] }, org, '2025-01-06', 'self')).toThrow();
  });
});
