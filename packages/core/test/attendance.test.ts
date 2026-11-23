import { describe, expect, it } from 'vitest';
import {
  allowedActions,
  dedupeEvents,
  nextStatus,
  recordEvent,
  replayAttendance,
  sessionTotals,
  type AttendanceEvent,
  type AttendanceEventType,
} from '../src';
import { ALICE, CARA, ORG } from './fixtures';

const TZ = 'Asia/Manila'; // UTC+8, no DST
let seq = 0;
const ev = (type: AttendanceEventType, occurredAt: string, key = `k${++seq}`): AttendanceEvent => ({
  id: `e_${key}`,
  idempotencyKey: key,
  organizationId: ORG,
  userId: ALICE,
  type,
  occurredAt,
  source: 'mobile',
});
const opts = (now = '2026-11-23T12:00:00Z') => ({ timeZone: TZ, now: new Date(now) });

describe('status machine', () => {
  it('allows only valid transitions', () => {
    expect(allowedActions('off')).toEqual(['clock_in']);
    expect(allowedActions('working')).toEqual(['break_start', 'clock_out']);
    expect(allowedActions('on_break')).toEqual(['break_end', 'clock_out']);
    expect(nextStatus('off', 'clock_out')).toMatchObject({ ok: false, error: { code: 'invalid_transition' } });
    expect(nextStatus('working', 'clock_in').ok).toBe(false);
  });
});

describe('replayAttendance', () => {
  it('derives a closed session with breaks', () => {
    const log = [
      ev('clock_in', '2026-11-23T00:00:00Z'),
      ev('break_start', '2026-11-23T04:00:00Z'),
      ev('break_end', '2026-11-23T04:45:00Z'),
      ev('clock_out', '2026-11-23T09:00:00Z'),
    ];
    const r = replayAttendance(log, opts());
    expect(r.status).toBe('off');
    expect(r.exceptions).toEqual([]);
    expect(r.sessions).toHaveLength(1);
    const s = r.sessions[0]!;
    expect(s.workDate).toBe('2026-11-23');
    expect(s.overnight).toBe(false);
    const t = sessionTotals(s, new Date('2026-11-23T12:00:00Z'));
    expect(t.breakMs / 60_000).toBe(45);
    expect(t.workedMs / 60_000).toBe(9 * 60 - 45);
  });

  it('attributes overnight shifts to the clock-in date in the organization zone', () => {
    // 22:00 → 06:00 Manila time.
    const log = [ev('clock_in', '2026-11-22T14:00:00Z'), ev('clock_out', '2026-11-22T22:00:00Z')];
    const s = replayAttendance(log, opts()).sessions[0]!;
    expect(s.workDate).toBe('2026-11-22');
    expect(s.overnight).toBe(true);
  });

  it('is unaffected by duplicate deliveries and arrival order', () => {
    const a = ev('clock_in', '2026-11-23T00:00:00Z', 'same');
    const dup = { ...a, id: 'e_retry' };
    const out = ev('clock_out', '2026-11-23T08:00:00Z');
    const r1 = replayAttendance([out, dup, a], opts());
    const r2 = replayAttendance([a, out], opts());
    expect(r1.sessions).toEqual(r2.sessions);
    expect(dedupeEvents([out, dup, a])).toHaveLength(2);
  });

  it('flags out-of-sequence events without corrupting state', () => {
    const log = [ev('break_end', '2026-11-23T00:00:00Z'), ev('clock_in', '2026-11-23T01:00:00Z')];
    const r = replayAttendance(log, opts());
    expect(r.status).toBe('working');
    expect(r.exceptions.map((e) => e.kind)).toEqual(['out_of_sequence']);
  });

  it('auto-closes an open break on clock-out and flags it', () => {
    const log = [
      ev('clock_in', '2026-11-23T00:00:00Z'),
      ev('break_start', '2026-11-23T03:00:00Z'),
      ev('clock_out', '2026-11-23T04:00:00Z'),
    ];
    const r = replayAttendance(log, opts());
    expect(r.exceptions.map((e) => e.kind)).toEqual(['break_not_ended']);
    expect(sessionTotals(r.sessions[0]!, new Date()).breakMs).toBe(3_600_000);
  });

  it('flags missed clock-outs on long open sessions', () => {
    const log = [ev('clock_in', '2026-11-22T00:00:00Z')];
    expect(replayAttendance(log, opts('2026-11-22T10:00:00Z')).exceptions).toEqual([]);
    expect(replayAttendance(log, opts('2026-11-22T17:00:00Z')).exceptions[0]?.kind).toBe('missed_clock_out');
  });

  it('runs open intervals until now for live totals', () => {
    const log = [ev('clock_in', '2026-11-23T00:00:00Z'), ev('break_start', '2026-11-23T02:00:00Z')];
    const r = replayAttendance(log, opts('2026-11-23T02:30:00Z'));
    expect(r.status).toBe('on_break');
    const t = sessionTotals(r.sessions[0]!, new Date('2026-11-23T02:30:00Z'));
    expect(t.workedMs / 60_000).toBe(120);
    expect(t.breakMs / 60_000).toBe(30);
  });
});

describe('recordEvent', () => {
  const log = [ev('clock_in', '2026-11-23T00:00:00Z', 'in1')];

  it('is idempotent for retried deliveries', () => {
    const retry = { ...ev('clock_in', '2026-11-23T00:00:05Z', 'in1'), id: 'different' };
    const r = recordEvent(log, retry, opts());
    expect(r).toMatchObject({ ok: true, value: { duplicate: true, event: log[0] } });
  });

  it('accepts a valid next event and rejects invalid ones', () => {
    expect(recordEvent(log, ev('clock_out', '2026-11-23T08:00:00Z'), opts())).toMatchObject({
      ok: true,
      value: { duplicate: false },
    });
    expect(recordEvent(log, ev('clock_in', '2026-11-23T08:00:00Z'), opts())).toMatchObject({
      ok: false,
      error: { code: 'invalid_transition' },
    });
  });

  it('rejects backdated events and foreign logs', () => {
    expect(recordEvent(log, ev('clock_out', '2026-11-22T08:00:00Z'), opts())).toMatchObject({
      ok: false,
      error: { code: 'out_of_order' },
    });
    const foreign = { ...ev('clock_out', '2026-11-23T08:00:00Z'), userId: CARA };
    expect(recordEvent(log, foreign, opts())).toMatchObject({ ok: false, error: { code: 'scope_mismatch' } });
  });
});
