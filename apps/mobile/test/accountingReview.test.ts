import { describe, expect, it } from 'vitest';
import { parseAccountingSnapshot, parsePersonalPayroll, parsePersonalPayrollDetail, formatPayslipDecimal, formatPayslipInstant } from '@/data/accountingReview';

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

const personalDetail={summary:personal,frequency:'monthly',exemptCents:'0',taxableCents:'2755000',taxDeductibleCents:'245000',basicCents:'3000000',premiumCents:'0',paymentConfirmed:false,items:[{date:'2026-02-02',code:'REG',start:null,end:null,seconds:'28800',hourlyRate:'123.2876712328767123',multiplier:'1',recordedAmount:null,siteReference:'fictional-site',method:'monthly_increment'}]};
describe('personal payroll detailed contract',()=>{
 it('accepts verified period evidence without inventing payment',()=>expect(parsePersonalPayrollDetail(personalDetail,org,employee,'2026-02-01').items[0]?.seconds).toBe('28800'));
 it('accepts the canonical semi-monthly server frequency',()=>expect(parsePersonalPayrollDetail({...personalDetail,frequency:'semi-monthly'},org,employee,'2026-02-01').frequency).toBe('semi-monthly'));
 it('rejects additional sensitive fields even inside a line',()=>{
   expect(()=>parsePersonalPayrollDetail({...personalDetail,items:[{...personalDetail.items[0],employerCost:'1000'}]},org,employee,'2026-02-01')).toThrow();
   expect(()=>parsePersonalPayrollDetail({...personalDetail,rawEvidence:{}},org,employee,'2026-02-01')).toThrow();
 });
 it('rejects false payment, wrong tax and out-of-period evidence',()=>{
   expect(()=>parsePersonalPayrollDetail({...personalDetail,paymentConfirmed:true},org,employee,'2026-02-01')).toThrow();
   expect(()=>parsePersonalPayrollDetail({...personalDetail,taxableCents:'1'},org,employee,'2026-02-01')).toThrow();
   expect(()=>parsePersonalPayrollDetail({...personalDetail,items:[{...personalDetail.items[0],date:'2026-03-01'}]},org,employee,'2026-02-01')).toThrow();
 });
});

describe('extended payslip privacy and amount sources',()=>{
 it('accepts exact employee-only SSS breakdown',()=>expect(parsePersonalPayrollDetail({...personalDetail,sssRegularCents:'100000',sssMpfCents:'50000'},org,employee,'2026-02-01').sssRegularCents).toBe('100000'));
 it('rejects mismatched and partial contribution splits',()=>{
  expect(()=>parsePersonalPayrollDetail({...personalDetail,sssRegularCents:'100001',sssMpfCents:'50000'},org,employee,'2026-02-01')).toThrow();
  expect(()=>parsePersonalPayrollDetail({...personalDetail,sssRegularCents:'100000'},org,employee,'2026-02-01')).toThrow();
 });
 it('rejects simultaneous recorded and calculated amounts',()=>expect(()=>parsePersonalPayrollDetail({...personalDetail,items:[{...personalDetail.items[0],recordedAmount:'100',calculatedAmount:'100'}]},org,employee,'2026-02-01')).toThrow());
});

describe('display-only payslip amounts and Manila time',()=>{
 it('rounds exact decimal values without floating point',()=>{
  expect(formatPayslipDecimal('1150.684931506849315')).toBe('₱1,150.68');
  expect(formatPayslipDecimal('99999999999999999999.995')).toBe('₱100,000,000,000,000,000,000.00');
  expect(formatPayslipDecimal('0')).toBe('₱0.00');
 });
 it('uses explicit Manila zone and rejects missing offsets',()=>{
  expect(formatPayslipInstant('2026-02-02T01:00:00Z','en')).toBe(formatPayslipInstant('2026-02-02T09:00:00+08:00','en'));
  expect(formatPayslipInstant('2026-02-02T09:00:00','en')).toBeNull();
  expect(formatPayslipInstant('invalid','en')).toBeNull();
 });
});
