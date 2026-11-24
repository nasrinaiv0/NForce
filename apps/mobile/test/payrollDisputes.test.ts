import { describe,expect,it } from 'vitest';
import { parseDisputeReview,parseOwnDisputes } from '@/data/payrollDisputes';
const org='fb100000-0000-4000-8000-000000000001',employee='fb000000-0000-4000-8000-000000000002',reviewer='fb000000-0000-4000-8000-000000000004',period='2026-02-01';
const row={userId:employee,revision:1,itemIndex:0,status:'submitted',reason:'Fictional dispute reason',submittedAt:'2026-03-01T00:00:00Z',proposal:null,explanation:null,decisionReason:null,canPropose:true,canDecide:false};
const payload={organizationId:org,periodStart:period,rows:[row]};
describe('dispute review field and scope checks',()=>{
 it('rejects cross-tenant and self review',()=>{
  expect(parseDisputeReview(payload,org,period,reviewer).rows).toHaveLength(1);
  expect(()=>parseDisputeReview(payload,org,period,employee)).toThrow();
  expect(()=>parseDisputeReview(payload,employee,period,reviewer)).toThrow();
 });
 it('rejects extra confidential fields and inconsistent permissions',()=>{
  expect(()=>parseDisputeReview({...payload,rows:[{...row,employerCost:'500'}]},org,period,reviewer)).toThrow();
  expect(()=>parseDisputeReview({...payload,rows:[{...row,canDecide:true}]},org,period,reviewer)).toThrow();
 });
 it('does not reveal pending proposal explanation to employee',()=>{
  const x={periodStart:period,revision:1,itemIndex:0,status:'pending_approval',explanation:null};
  expect(parseOwnDisputes([x],period)).toHaveLength(1);
  expect(()=>parseOwnDisputes([{...x,explanation:'Confidential draft'}],period)).toThrow();
  expect(()=>parseOwnDisputes([x],'2026-03-01')).toThrow();
 });
});
