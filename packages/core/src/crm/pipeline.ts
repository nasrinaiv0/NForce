import { err, ok, type DomainError, type Result } from '../result';

/** CRM opportunity pipeline: stage rules and forecast. */

export const DEAL_STAGES = ['lead', 'qualified', 'proposal', 'negotiation', 'won', 'lost'] as const;
export type DealStage = (typeof DEAL_STAGES)[number];

/** Default win probability per stage (organizations may override). */
export const STAGE_PROBABILITY: Readonly<Record<DealStage, number>> = {
  lead: 0.1,
  qualified: 0.25,
  proposal: 0.5,
  negotiation: 0.75,
  won: 1,
  lost: 0,
};

export interface Deal {
  readonly id: string;
  readonly name: string;
  readonly account: string;
  readonly ownerName: string;
  readonly stage: DealStage;
  /** Minor currency units (e.g. centavos) to avoid floating-point money. */
  readonly amountMinor: number;
  readonly currency: string;
  readonly closeDate: string;
}

export type DealErrorCode = 'closed_deal' | 'unknown_stage' | 'reason_required';

export const isClosed = (s: DealStage) => s === 'won' || s === 'lost';

/** Move a deal. Closed deals cannot move; losing a deal requires a reason. */
export function moveDeal(deal: Deal, to: DealStage, reason?: string): Result<Deal, DomainError<DealErrorCode>> {
  if (!DEAL_STAGES.includes(to)) return err({ code: 'unknown_stage', message: `Unknown stage ${to}.` });
  if (isClosed(deal.stage)) return err({ code: 'closed_deal', message: 'Closed deals cannot be moved; create a new opportunity.' });
  if (to === 'lost' && (reason === undefined || reason.trim().length === 0)) {
    return err({ code: 'reason_required', message: 'Record why the deal was lost.' });
  }
  return ok({ ...deal, stage: to });
}

export interface PipelineSummary {
  readonly byStage: readonly { stage: DealStage; count: number; amountMinor: number }[];
  readonly openAmountMinor: number;
  /** Σ amount × stage probability over open deals. */
  readonly weightedForecastMinor: number;
  readonly wonAmountMinor: number;
  readonly winRate: number;
}

export function pipelineSummary(deals: readonly Deal[]): PipelineSummary {
  const byStage = DEAL_STAGES.map((stage) => {
    const list = deals.filter((d) => d.stage === stage);
    return { stage, count: list.length, amountMinor: list.reduce((n, d) => n + d.amountMinor, 0) };
  });
  const open = deals.filter((d) => !isClosed(d.stage));
  const won = deals.filter((d) => d.stage === 'won');
  const lost = deals.filter((d) => d.stage === 'lost');
  return {
    byStage,
    openAmountMinor: open.reduce((n, d) => n + d.amountMinor, 0),
    weightedForecastMinor: Math.round(open.reduce((n, d) => n + d.amountMinor * STAGE_PROBABILITY[d.stage], 0)),
    wonAmountMinor: won.reduce((n, d) => n + d.amountMinor, 0),
    winRate: won.length + lost.length === 0 ? 0 : won.length / (won.length + lost.length),
  };
}
