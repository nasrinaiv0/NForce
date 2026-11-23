/** Approval service levels: how fast requests get decided, and what is aging. */

export interface ApprovalRecord {
  readonly kind: string;
  readonly submittedAt: string;
  readonly decidedAt?: string;
  readonly status: 'pending' | 'approved' | 'returned';
}

export interface ApprovalSla {
  readonly total: number;
  readonly pending: number;
  readonly approved: number;
  readonly returned: number;
  readonly approvalRate: number;
  readonly medianHoursToDecide: number;
  readonly p90HoursToDecide: number;
  /** Pending longer than the SLA threshold. */
  readonly overdue: number;
  readonly byKind: readonly { kind: string; total: number; pending: number }[];
}

/** Nearest-rank percentile of a non-empty ascending list. */
export function percentile(sorted: readonly number[], p: number): number {
  if (sorted.length === 0) return 0;
  const rank = Math.min(sorted.length, Math.max(1, Math.ceil((p / 100) * sorted.length)));
  return sorted[rank - 1] ?? 0;
}

export function approvalSla(records: readonly ApprovalRecord[], now: Date, slaHours = 48): ApprovalSla {
  const hours = records
    .filter((r) => r.decidedAt !== undefined)
    .map((r) => (Date.parse(r.decidedAt ?? r.submittedAt) - Date.parse(r.submittedAt)) / 3_600_000)
    .sort((a, b) => a - b);
  const pending = records.filter((r) => r.status === 'pending');
  const approved = records.filter((r) => r.status === 'approved').length;
  const returned = records.filter((r) => r.status === 'returned').length;
  const kinds = [...new Set(records.map((r) => r.kind))].sort();
  return {
    total: records.length,
    pending: pending.length,
    approved,
    returned,
    approvalRate: approved + returned === 0 ? 1 : approved / (approved + returned),
    medianHoursToDecide: percentile(hours, 50),
    p90HoursToDecide: percentile(hours, 90),
    overdue: pending.filter((r) => now.getTime() - Date.parse(r.submittedAt) > slaHours * 3_600_000).length,
    byKind: kinds.map((kind) => ({
      kind,
      total: records.filter((r) => r.kind === kind).length,
      pending: pending.filter((r) => r.kind === kind).length,
    })),
  };
}
