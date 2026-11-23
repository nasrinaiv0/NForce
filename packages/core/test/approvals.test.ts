import { describe, expect, it } from 'vitest';
import {
  UserId,
  buildApprovalChain,
  currentApprovers,
  decideApproval,
  managerChain,
  type ApprovalState,
  type OrgMember,
} from '../src';

const u = UserId;
// VP ← Manager ← Supervisor ← Staff; HR reports to VP.
const people: OrgMember[] = [
  { id: u('vp'), roles: ['executive'] },
  { id: u('mgr'), managerId: u('vp'), roles: ['manager'] },
  { id: u('sup'), managerId: u('mgr'), roles: ['supervisor'] },
  { id: u('staff'), managerId: u('sup'), roles: ['staff'] },
  { id: u('hr'), managerId: u('vp'), roles: ['hr'] },
  { id: u('orphan'), roles: ['staff'] },
];
const dir = new Map(people.map((p) => [p.id, p]));
const must = <T>(r: { ok: true; value: T } | { ok: false; error: unknown }): T => {
  if (!r.ok) throw new Error(JSON.stringify(r.error));
  return r.value;
};

describe('routing', () => {
  it('routes staff requests to supervisor review then manager approval', () => {
    const s = must(buildApprovalChain(u('staff'), dir));
    expect(s.steps.map((x) => [x.level, x.approverId, x.status])).toEqual([
      ['supervisor', 'sup', 'pending'],
      ['manager', 'mgr', 'waiting'],
    ]);
    expect(currentApprovers(s)).toEqual(['sup', 'mgr']);
  });

  it("sends a supervisor's own request straight to the manager", () => {
    const s = must(buildApprovalChain(u('sup'), dir));
    expect(s.steps.map((x) => [x.level, x.approverId])).toEqual([['manager', 'mgr']]);
  });

  it("sends a manager's own request to the next manager-tier person", () => {
    expect(must(buildApprovalChain(u('mgr'), dir)).steps.map((x) => x.approverId)).toEqual(['vp']);
    expect(must(buildApprovalChain(u('hr'), dir)).steps.map((x) => x.approverId)).toEqual(['vp']);
  });

  it('fails safely without an approver, for unknown people, and on cycles', () => {
    expect(buildApprovalChain(u('vp'), dir)).toMatchObject({ ok: false, error: { code: 'no_approver' } });
    expect(buildApprovalChain(u('orphan'), dir)).toMatchObject({ ok: false, error: { code: 'no_approver' } });
    expect(buildApprovalChain(u('ghost'), dir)).toMatchObject({ ok: false, error: { code: 'unknown_requester' } });
    const cyc = new Map(dir);
    cyc.set(u('vp'), { id: u('vp'), managerId: u('staff'), roles: ['executive'] });
    expect(managerChain(u('staff'), cyc)).toMatchObject({ ok: false, error: { code: 'reporting_cycle' } });
  });
});

describe('decisions', () => {
  const fresh = (): ApprovalState => must(buildApprovalChain(u('staff'), dir));

  it('supervisor endorses, then manager gives final approval', () => {
    const endorsed = must(decideApproval(fresh(), u('sup'), 'approve'));
    expect(endorsed.status).toBe('pending');
    expect(endorsed.steps.map((s) => s.status)).toEqual(['approved', 'pending']);
    expect(currentApprovers(endorsed)).toEqual(['mgr']);
    const final = must(decideApproval(endorsed, u('mgr'), 'approve'));
    expect(final.status).toBe('approved');
    expect(currentApprovers(final)).toEqual([]);
  });

  it('lets the manager approve at any stage, skipping the pending review', () => {
    const final = must(decideApproval(fresh(), u('mgr'), 'approve', { now: new Date('2026-11-23T00:00:00Z') }));
    expect(final.status).toBe('approved');
    expect(final.steps.map((s) => s.status)).toEqual(['skipped', 'approved']);
    expect(final.steps[1]).toMatchObject({ decidedBy: 'mgr', decidedAt: '2026-11-23T00:00:00.000Z' });
  });

  it('returns with a mandatory reason', () => {
    expect(decideApproval(fresh(), u('sup'), 'return')).toMatchObject({ ok: false, error: { code: 'reason_required' } });
    const r = must(decideApproval(fresh(), u('sup'), 'return', { reason: ' Wrong dates ' }));
    expect(r.status).toBe('returned');
    expect(r.steps[0]).toMatchObject({ status: 'returned', reason: 'Wrong dates' });
  });

  it('blocks self-approval, outsiders, executives above the chain, and closed requests', () => {
    expect(decideApproval(fresh(), u('staff'), 'approve')).toMatchObject({ ok: false, error: { code: 'self_approval' } });
    expect(decideApproval(fresh(), u('hr'), 'approve')).toMatchObject({ ok: false, error: { code: 'not_approver' } });
    expect(decideApproval(fresh(), u('vp'), 'approve')).toMatchObject({ ok: false, error: { code: 'not_approver' } });
    const done = must(decideApproval(fresh(), u('mgr'), 'approve'));
    expect(decideApproval(done, u('mgr'), 'approve')).toMatchObject({ ok: false, error: { code: 'closed' } });
  });
});
