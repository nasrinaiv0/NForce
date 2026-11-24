import { z } from 'zod';

const minutes = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
export const accountingSnapshotSchema = z.object({
  organizationId: z.uuid(),
  periodStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  scope: z.enum(['self', 'organization']),
  source: z.literal('locked-original-v3'),
  employeeCount: z.number().int().positive(),
  workedMinutes: minutes,
  approvedOvertimeMinutes: minutes,
  lines: z.array(z.object({ code: z.string().regex(/^(REG|RD|SH|SH_RD|RH|RH_RD)(_OT)?(_ND)?$/), minutes })),
}).refine((s) => s.approvedOvertimeMinutes <= s.workedMinutes && s.lines.reduce((sum, row) => sum + row.minutes, 0) <= s.workedMinutes);

export type AccountingScope = 'self' | 'organization';
export function parseAccountingSnapshot(raw: unknown, organizationId: string, periodStart: string, scope: AccountingScope) {
  const value = accountingSnapshotSchema.parse(raw);
  if (value.organizationId !== organizationId || value.periodStart !== periodStart || value.scope !== scope) {
    throw new Error('Accounting snapshot scope mismatch');
  }
  return value;
}
