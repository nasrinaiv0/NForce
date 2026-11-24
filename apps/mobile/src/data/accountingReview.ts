import { z } from 'zod';

const seconds = z.string().regex(/^\d{1,12}(?:\.\d{1,6})?$/);
const micros = (v: string): bigint => { const [whole = '0', fraction = ''] = v.split('.'); return BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, '0')); };
export const accountingSnapshotSchema = z.object({
  organizationId: z.uuid(),
  periodStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  scope: z.enum(['self', 'organization']),
  source: z.literal('locked-original-ph-v4'),
  employeeCount: z.number().int().positive(),
  workedSeconds: seconds,
  overtimeSeconds: seconds,
  lines: z.array(z.object({ code: z.string().regex(/^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$/), seconds })),
}).refine((s) => micros(s.overtimeSeconds) <= micros(s.workedSeconds) && s.lines.reduce((sum, row) => sum + micros(row.seconds), 0n) === micros(s.workedSeconds));

export type AccountingScope = 'self' | 'organization';
export function parseAccountingSnapshot(raw: unknown, organizationId: string, periodStart: string, scope: AccountingScope) {
  const value = accountingSnapshotSchema.parse(raw);
  if (value.organizationId !== organizationId || value.periodStart !== periodStart || value.scope !== scope) {
    throw new Error('Accounting snapshot scope mismatch');
  }
  return value;
}
