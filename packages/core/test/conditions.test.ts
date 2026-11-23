import { describe, expect, it } from 'vitest';
import { OPERATORS, accessorsFor, activeConditionCount, applyConditions, isComplete, newCondition, sortItems, type Condition, type FieldDef } from '../src';

interface Row {
  name: string;
  team?: string;
  status: 'pending' | 'approved' | 'returned';
  roles: string[];
  ot: number; // minutes
  rate: number; // 0–1
  start?: string; // date key or ISO
  night: boolean;
}
const rows: Row[] = [
  { name: 'José Rizal', team: 'Billing', status: 'pending', roles: ['staff'], ot: 150, rate: 0.98, start: '2026-12-01', night: false },
  { name: 'Maya Santos', team: 'Customer Success', status: 'approved', roles: ['supervisor'], ot: 0, rate: 0.91, start: '2026-11-20T09:00:00Z', night: false },
  { name: 'Diego Ramos', status: 'returned', roles: ['staff'], ot: 45, rate: 1, night: true },
];
const fields: FieldDef<Row>[] = [
  { key: 'name', label: 'Name', kind: 'text', get: (r) => r.name },
  { key: 'team', label: 'Team', kind: 'text', get: (r) => r.team },
  {
    key: 'status',
    label: 'Status',
    kind: 'choice',
    get: (r) => r.status,
    options: [
      { value: 'pending', label: 'Pending' },
      { value: 'approved', label: 'Approved' },
      { value: 'returned', label: 'Returned' },
    ],
  },
  { key: 'roles', label: 'Roles', kind: 'choice', get: (r) => r.roles, options: [{ value: 'staff', label: 'Staff' }, { value: 'supervisor', label: 'Supervisor' }] },
  { key: 'ot', label: 'OT', kind: 'duration', get: (r) => r.ot },
  { key: 'rate', label: 'Rate', kind: 'percent', get: (r) => r.rate },
  { key: 'start', label: 'Start', kind: 'date', get: (r) => r.start },
  { key: 'night', label: 'Night', kind: 'boolean', get: (r) => r.night },
];
const c = (field: string, op: Condition['op'], value?: Condition['value'], value2?: Condition['value2']): Condition => ({
  id: `${field}-${op}`,
  field,
  op,
  ...(value !== undefined ? { value } : {}),
  ...(value2 !== undefined ? { value2 } : {}),
});
const names = (conds: Condition[], match: 'all' | 'any' = 'all') => applyConditions(rows, fields, conds, match).map((r) => r.name.split(' ')[0]);

describe('custom filter conditions', () => {
  it('matches text accent- and case-insensitively', () => {
    expect(names([c('name', 'contains', 'jose')])).toEqual(['José']);
    expect(names([c('name', 'starts_with', 'ma')])).toEqual(['Maya']);
    expect(names([c('name', 'not_contains', 'diego')])).toEqual(['José', 'Maya']);
    expect(names([c('team', 'is', 'billing')])).toEqual(['José']);
    expect(names([c('team', 'is_empty')])).toEqual(['Diego']);
    expect(names([c('team', 'not_empty')])).toEqual(['José', 'Maya']);
  });

  it('matches choices, including multi-valued ones', () => {
    expect(names([c('status', 'any_of', ['pending', 'returned'])])).toEqual(['José', 'Diego']);
    expect(names([c('status', 'none_of', ['pending'])])).toEqual(['Maya', 'Diego']);
    expect(names([c('roles', 'any_of', ['supervisor'])])).toEqual(['Maya']);
  });

  it('compares numbers, durations and percents, with between in either order', () => {
    expect(names([c('ot', 'gt', 60)])).toEqual(['José']);
    expect(names([c('ot', 'between', 60, 30)])).toEqual(['Diego']);
    expect(names([c('rate', 'lt', 0.95)])).toEqual(['Maya']);
    expect(names([c('ot', 'eq', '0')])).toEqual(['Maya']);
  });

  it('compares dates and instants by calendar day', () => {
    expect(names([c('start', 'on_or_after', '2026-11-25')])).toEqual(['José']);
    expect(names([c('start', 'on', '2026-11-20')])).toEqual(['Maya']);
    expect(names([c('start', 'between', '2026-12-31', '2026-11-01')])).toEqual(['José', 'Maya']);
    expect(names([c('start', 'before', '2026-12-01')])).toEqual(['Maya']);
    expect(names([c('start', 'is_empty')])).toEqual(['Diego']);
  });

  it('covers every number and date operator', () => {
    expect(names([c('ot', 'neq', 0)])).toEqual(['José', 'Diego']);
    expect(names([c('ot', 'gte', 45)])).toEqual(['José', 'Diego']);
    expect(names([c('ot', 'lte', 45)])).toEqual(['Maya', 'Diego']);
    expect(names([c('ot', 'lt', 45)])).toEqual(['Maya']);
    expect(names([c('rate', 'gte', 0.98)])).toEqual(['José', 'Diego']);
    expect(names([c('rate', 'gt', 0.98)])).toEqual(['Diego']);
    expect(names([c('rate', 'lte', 0.91)])).toEqual(['Maya']);
    expect(names([c('rate', 'between', 0.9, 0.95)])).toEqual(['Maya']);
    expect(names([c('start', 'after', '2026-11-20')])).toEqual(['José']);
    expect(names([c('start', 'on_or_before', '2026-11-20')])).toEqual(['Maya']);
    expect(names([c('start', 'not_empty')])).toEqual(['José', 'Maya']);
    expect(names([c('team', 'is_not', 'billing')])).toEqual(['Maya', 'Diego']);
    expect(names([c('roles', 'is_empty')])).toEqual([]);
    expect(names([c('roles', 'not_empty')])).toEqual(['José', 'Maya', 'Diego']);
  });

  it('handles booleans and combines conditions with all or any', () => {
    expect(names([c('night', 'is_true')])).toEqual(['Diego']);
    expect(names([c('night', 'is_false')])).toEqual(['José', 'Maya']);
    const both = [c('status', 'any_of', ['pending']), c('night', 'is_true')];
    expect(names(both, 'all')).toEqual([]);
    expect(names(both, 'any')).toEqual(['José', 'Diego']);
  });

  it('ignores incomplete or invalid conditions instead of hiding everything', () => {
    const incomplete = [c('name', 'contains', '  '), c('ot', 'gt'), c('status', 'any_of', []), c('start', 'between', '2026-11-01'), c('missing', 'is', 'x'), c('rate', 'contains', 'x')];
    expect(names(incomplete)).toEqual(['José', 'Maya', 'Diego']);
    expect(activeConditionCount(fields, incomplete)).toBe(0);
    expect(activeConditionCount(fields, [c('night', 'is_true'), c('ot', 'gt', 1)])).toBe(2);
    expect(isComplete(fields[0] as FieldDef<unknown>, c('name', 'is_empty'))).toBe(true);
  });

  it('starts new conditions with the first operator for the field kind', () => {
    for (const f of fields) {
      const n = newCondition(f, 'x');
      expect(n.op).toBe(OPERATORS[f.kind][0]);
      if (f.kind === 'choice') expect(n.value).toEqual([]);
    }
  });

  it('never mutates the input', () => {
    const copy = structuredClone(rows);
    applyConditions(rows, fields, [c('ot', 'gt', 1)]);
    expect(rows).toEqual(copy);
  });
});

describe('sorting by any field', () => {
  const acc = accessorsFor(fields);
  const order = (key: string, direction: 'asc' | 'desc' = 'asc') => sortItems(rows, acc, { key, direction }).map((r) => r.name.split(' ')[0]);
  it('sorts text, numbers, dates and booleans, missing values last', () => {
    expect(order('name')).toEqual(['Diego', 'José', 'Maya']);
    expect(order('ot', 'desc')).toEqual(['José', 'Diego', 'Maya']);
    expect(order('start')).toEqual(['Maya', 'José', 'Diego']);
    expect(order('start', 'desc')).toEqual(['José', 'Maya', 'Diego']);
    expect(order('team', 'desc')).toEqual(['Maya', 'José', 'Diego']);
  });
  it('sorts choices in their natural order and joins multi-values', () => {
    expect(order('status')).toEqual(['José', 'Maya', 'Diego']);
    expect(order('status', 'desc')).toEqual(['Diego', 'Maya', 'José']);
    expect(order('roles')).toEqual(['José', 'Diego', 'Maya']);
  });
  it('skips fields marked not sortable', () => {
    expect(Object.keys(accessorsFor([{ key: 'x', label: 'X', kind: 'text', get: () => '', sortable: false }]))).toEqual([]);
  });
});
