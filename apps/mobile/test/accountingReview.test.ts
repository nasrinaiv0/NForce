import { describe, expect, it } from 'vitest';
import { parseAccountingSnapshot, parsePersonalPayroll, parsePersonalPayrollDetail, formatPayslipDecimal, formatPayslipInstant, parsePayrollHistory, parseDisputeReceipts } from '@/data/accountingReview';

import { buildPayslipPdf } from '@/data/payslipPdf';

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

describe('released history and dispute scope',()=>{
 const h={organizationId:org,userId:employee,year:2026,coverageComplete:false,periods:[personal],periodCount:1,grossCents:personal.grossCents,employeeContributionCents:personal.employeeContributionCents,withholdingCents:personal.withholdingCents,netCents:personal.netCents,exemptCents:'0',taxableCents:'2755000'};
 it('reconciles history totals and rejects duplicated periods and leaked fields',()=>{
  expect(parsePayrollHistory(h,org,employee).netCents).toBe(personal.netCents);
  expect(()=>parsePayrollHistory({...h,netCents:'1'},org,employee)).toThrow();
  expect(()=>parsePayrollHistory({...h,periods:[personal,personal],periodCount:2},org,employee)).toThrow();
  expect(()=>parsePayrollHistory({...h,employerCostCents:'1'},org,employee)).toThrow();
  expect(()=>parsePayrollHistory(h,org,'other')).toThrow();
 });
 it('rejects a receipt from another revision or period',()=>{
  const r={status:'submitted',periodStart:'2026-02-01',revision:1,itemIndex:0,submittedAt:'2026-03-01T00:00:00Z'};
  expect(parseDisputeReceipts([r],'2026-02-01',1)).toHaveLength(1);
  expect(()=>parseDisputeReceipts([r],'2026-02-01',2)).toThrow();
  expect(()=>parseDisputeReceipts([{...r,reason:'private'}],'2026-02-01',1)).toThrow();
 });
 it('generates an embedded Unicode PDF with valid cross reference offsets',()=>{
  const d=parsePersonalPayrollDetail(personalDetail,org,employee,'2026-02-01');
  const pdf=buildPayslipPdf(d,true);
  expect(pdf).toContain('/Subtype /CIDFontType2');
  expect(pdf).toContain('/FontFile2');
  expect(pdf).toContain('/ToUnicode');
  expect(pdf).toMatch(/<[0-9A-F]{4}> <20B1>/);
  expect(pdf).not.toMatch(/employer contribution|employer cost|\/JavaScript|\/OpenAction/i);
  const start=Number(pdf.match(/startxref\n(\d+)/)?.[1]);
  expect(pdf.slice(start,start+4)).toBe('xref');
  const entries=pdf.slice(start).split('\n').slice(3).filter(x=>/^\d{10} 00000 n /.test(x));
  entries.forEach((x,i)=>expect(pdf.slice(Number(x.slice(0,10)))).toMatch(new RegExp('^'+(i+1)+' 0 obj')));
 });
});

describe('Unicode payslip export',()=>{
 it('supports Filipino and Spanish accented text and NFC composition',()=>{
  const detail=parsePersonalPayrollDetail({...personalDetail,items:[{...personalDetail.items[0],siteReference:'Peña, Cagaya\u0301n, Zürich'}]},org,employee,'2026-02-01');
  const pdf=buildPayslipPdf(detail,true);
  for(const cp of ['00F1','00E1','00FC','20B1'])expect(pdf).toMatch(new RegExp('<[0-9A-F]{4}> <'+cp+'>'));
 });
 it('fails closed for unsupported scripts and bidi controls',()=>{
  for(const siteReference of ['中文','Office\u202E','x\u0301']){
   const detail=parsePersonalPayrollDetail({...personalDetail,items:[{...personalDetail.items[0],siteReference}]},org,employee,'2026-02-01');
   expect(()=>buildPayslipPdf(detail,true)).toThrow('Unsupported payslip PDF glyph');
  }
 });
});
