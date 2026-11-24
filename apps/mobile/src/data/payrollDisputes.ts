import { z } from 'zod';
const status=z.enum(['submitted','pending_approval','explanation','correction_required','declined']);
const base=z.object({revision:z.number().int().min(1).max(2),itemIndex:z.number().int().min(0).max(9999),status});
const row=base.extend({userId:z.uuid(),reason:z.string().min(10).max(500),submittedAt:z.string().max(50),proposal:z.enum(['explanation','correction_required']).nullable(),explanation:z.string().max(1000).nullable(),decisionReason:z.string().max(1000).nullable(),canPropose:z.boolean(),canDecide:z.boolean()}).strict().refine(r=>!(r.canPropose&&r.canDecide)&&(!r.canPropose||r.status==='submitted')&&(!r.canDecide||r.status==='pending_approval'));
const response=z.strictObject({organizationId:z.uuid(),periodStart:z.string().regex(/^\d{4}-\d{2}-\d{2}$/),rows:z.array(row)});
export type DisputeReviewRow=z.infer<typeof row>;
export function parseDisputeReview(raw:unknown,org:string,period:string,user:string){
 const d=response.parse(raw);
 if(d.organizationId!==org||d.periodStart!==period||d.rows.some(r=>r.userId===user&&(r.canPropose||r.canDecide)))throw new Error('Dispute scope mismatch');
 return d;
}
export const ownDisputeSchema=z.array(base.extend({periodStart:z.string().regex(/^\d{4}-\d{2}-\d{2}$/),explanation:z.string().max(1000).nullable()}).strict().refine(r=>(r.status==='explanation'||r.status==='correction_required')||r.explanation===null));
export function parseOwnDisputes(raw:unknown,period:string){
 const d=ownDisputeSchema.parse(raw);if(d.some(r=>r.periodStart!==period))throw new Error('Dispute scope mismatch');return d;
}
export const decisionResponse=z.strictObject({status});
