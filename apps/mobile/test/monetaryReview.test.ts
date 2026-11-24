import {describe, expect, it} from 'vitest';
import {formatPhpCents,parseMonetarySnapshot} from '@/data/accountingReview';
const org='fb100000-0000-4000-8000-000000000001';
const s={organizationId:org,periodStart:'2026-01-12',source:'original-posted-accrual-v1',employeeCount:1,grossCents:'121125',employeeContributionCents:'60000',employerContributionCents:'86000',withholdingCents:'0',exemptCents:'20000',netCents:'61125',employerCostCents:'207125'};
describe('server monetary review',()=>{
 it('keeps cent arithmetic exact',()=>{expect(parseMonetarySnapshot(s,org,s.periodStart).netCents).toBe('61125');expect(formatPhpCents('121125')).toBe('₱1,211.25');expect(formatPhpCents('12345678901234567890')).toBe('₱123,456,789,012,345,678.90');});
 it('rejects tampered totals and tenant/period mismatch',()=>{expect(()=>parseMonetarySnapshot({...s,netCents:'61126'},org,s.periodStart)).toThrow();expect(()=>parseMonetarySnapshot(s,'other',s.periodStart)).toThrow();expect(()=>parseMonetarySnapshot(s,org,'2026-01-19')).toThrow();});
});
