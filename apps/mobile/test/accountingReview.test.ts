import { describe, expect, it } from 'vitest';
import { parseAccountingSnapshot, parsePersonalPayroll } from '@/data/accountingReview';

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

const employee = 'fb000000-0000-4000-8000-000000000002';
const personal = { organizationId:org,userId:employee,periodStart:'2026-02-01',periodEnd:'2026-02-28',revision:1,source:'released-personal-accrual-v1',grossCents:'3000000',employeeContributionCents:'245000',sssEmployeeCents:'150000',philhealthEmployeeCents:'75000',pagibigEmployeeCents:'20000',withholdingCents:'100755',netCents:'2654245' };
describe('personal payroll response allowlist',()=>{
 it('accepts reconciled own deductions',()=>expect(parsePersonalPayroll(personal,org,employee,'2026-02-01').netCents).toBe('2654245'));
 it('rejects any employer contributions, cost or arbitrary evidence',()=>{
  for(const fields of [{employerContributionCents:'398000'},{employerCostCents:'3398000'},{journal:[]},{otherEmployee:{}}])
   expect(()=>parsePersonalPayroll({...personal,...fields},org,employee,'2026-02-01')).toThrow();
 });
 it('rejects identity, tenant, date and monetary mismatches',()=>{
  expect(()=>parsePersonalPayroll(personal,org,'other','2026-02-01')).toThrow();
  expect(()=>parsePersonalPayroll(personal,'other',employee,'2026-02-01')).toThrow();
  expect(()=>parsePersonalPayroll(personal,org,employee,'2026-02-02')).toThrow();
  expect(()=>parsePersonalPayroll({...personal,sssEmployeeCents:'1'},org,employee,'2026-02-01')).toThrow();
 });
});
