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

const cents = z.string().regex(/^\d{1,30}$/);
const monetarySchema = z.object({
  organizationId: z.uuid(), periodStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  source: z.literal('original-posted-accrual-v1'), employeeCount: z.number().int().positive(),
  grossCents: cents, employeeContributionCents: cents, employerContributionCents: cents,
  withholdingCents: cents, exemptCents: cents, netCents: cents, employerCostCents: cents,
}).refine((s) => BigInt(s.grossCents) === BigInt(s.netCents) + BigInt(s.employeeContributionCents) + BigInt(s.withholdingCents) &&
  BigInt(s.employerCostCents) === BigInt(s.grossCents) + BigInt(s.employerContributionCents) && BigInt(s.exemptCents) <= BigInt(s.grossCents));
export type MonetarySnapshot = z.infer<typeof monetarySchema>;
export function parseMonetarySnapshot(raw: unknown, organization: string, period: string) {
  const s = monetarySchema.parse(raw);
  if (s.organizationId !== organization || s.periodStart !== period) throw new Error('Monetary scope mismatch');
  return s;
}
export function formatPhpCents(value: string) {
  const s = value.padStart(3, '0');
  return '₱' + s.slice(0, -2).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + '.' + s.slice(-2);
}

/** Exact employee-only response: reject accidental additional confidential fields. */
const personalPayrollSchema = z.strictObject({
  organizationId: z.uuid(), userId: z.uuid(),
  periodStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), periodEnd: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  revision: z.number().int().min(1).max(2), source: z.literal('released-personal-accrual-v1'),
  grossCents: cents, employeeContributionCents: cents, sssEmployeeCents: cents,
  philhealthEmployeeCents: cents, pagibigEmployeeCents: cents, withholdingCents: cents, netCents: cents,
}).refine(s => s.periodEnd >= s.periodStart &&
  BigInt(s.employeeContributionCents) === BigInt(s.sssEmployeeCents) + BigInt(s.philhealthEmployeeCents) + BigInt(s.pagibigEmployeeCents) &&
  BigInt(s.grossCents) === BigInt(s.netCents) + BigInt(s.employeeContributionCents) + BigInt(s.withholdingCents));
export function parsePersonalPayroll(raw: unknown, organization: string, user: string, period: string) {
  const s = personalPayrollSchema.parse(raw);
  if (s.organizationId !== organization || s.userId !== user || s.periodStart !== period) throw new Error('Personal payroll scope mismatch');
  return s;
}
