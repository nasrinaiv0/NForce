import { OPERATORS, VALUELESS, accessorsFor, applyConditions, sortItems, type Condition, type FieldDef, type RoleTemplate } from '@nforce/core';
import { beforeAll, describe, expect, it } from 'vitest';

import {
  approvalFields,
  attendancePeopleFields,
  auditFields,
  dealFields,
  directReportFields,
  directoryFields,
  exceptionFields,
  groupFields,
  holidayFields,
  myRequestFields,
  notificationFields,
  payrollFields,
  rosterFields,
  taskFields,
  teamMemberFields,
  timesheetDayFields,
} from '@/data/listFields';
import { createMockApi } from '@/data/mockApi';
import { createI18n } from '@/i18n/core';

/**
 * Every list's sort and filter fields, exercised against real demo data:
 * each field sorts both ways, every operator runs, a value taken from the
 * data matches it, and every choice value in the data is offered as an option.
 */
const NOW = new Date('2026-11-23T02:30:00Z');
const i18n = createI18n('en', 'en-PH');
let persona: RoleTemplate = 'owner';
const api = createMockApi({ getPersona: () => persona, now: () => NOW, latencyMs: 0 });

const lists: { name: string; rows: unknown[]; fields: FieldDef<unknown>[] }[] = [];
const add = <T,>(name: string, rows: readonly T[], fields: FieldDef<T>[]) => lists.push({ name, rows: [...rows], fields: fields as FieldDef<unknown>[] });

beforeAll(async () => {
  persona = 'owner';
  add('approvals', await api.approvals(), approvalFields(i18n));
  add('team', await api.team(), teamMemberFields(i18n));
  add('people', await api.directory(), directoryFields(i18n));
  add('payroll', (await api.payroll()).rows, payrollFields(i18n));
  add('deals', await api.deals(), dealFields(i18n));
  const admin = await api.admin();
  add('audit', admin.audit, auditFields(i18n));
  add('holidays', admin.holidays, holidayFields(i18n));
  const report = await api.attendanceReport({ scope: 'org', weeks: 4 });
  add('attendance people', report.people, attendancePeopleFields(i18n));
  add('attendance groups', report.groups, groupFields(i18n));
  add('exceptions', report.exceptions, exceptionFields(i18n));
  add('executive teams', (await api.executiveReport()).teams, groupFields(i18n));
  add('roster', await api.teamSchedule('2026-11-23', '2026-11-29'), rosterFields(i18n));
  add('direct reports', (await api.profile((await api.session()).user.id)).directReports, directReportFields(i18n));
  persona = 'staff';
  add('my requests', await api.myRequests(), myRequestFields(i18n));
  add('tasks', await api.tasks(), taskFields(i18n));
  add('notifications', await api.notifications(), notificationFields(i18n));
  add('timesheet days', (await api.timesheet({ periodStart: '2026-11-16' })).days, timesheetDayFields(i18n));
});

const sample = (field: FieldDef<unknown>, rows: unknown[]) => {
  for (const r of rows) {
    const v = field.get(r);
    if (Array.isArray(v) ? v.length > 0 : v !== undefined && v !== null && v !== '') return v;
  }
  return undefined;
};

const conditionFor = (field: FieldDef<unknown>, op: Condition['op'], v: unknown): Condition => {
  const base = { id: 'c', field: field.key, op };
  if (VALUELESS.has(op)) return base;
  switch (field.kind) {
    case 'choice':
      return { ...base, value: Array.isArray(v) ? [String(v[0])] : [String(v)] };
    case 'text':
      return { ...base, value: String(v).slice(0, 3) };
    case 'date':
      return { ...base, value: String(v).slice(0, 10), value2: String(v).slice(0, 10) };
    default:
      return { ...base, value: Number(v), value2: Number(v) };
  }
};

describe('list fields on real data', () => {
  it('covers every list with data', () => {
    expect(lists.map((l) => [l.name, l.rows.length > 0])).toEqual(lists.map((l) => [l.name, true]));
  });

  it('labels every field and keeps keys unique per list', () => {
    for (const l of lists) {
      const keys = l.fields.map((f) => f.key);
      expect({ list: l.name, unique: new Set(keys).size === keys.length }).toEqual({ list: l.name, unique: true });
      for (const f of l.fields) expect({ list: l.name, field: f.key, label: f.label.startsWith('field.') }).toMatchObject({ label: false });
    }
  });

  it('sorts by every sortable field in both directions without losing rows', () => {
    for (const l of lists) {
      const acc = accessorsFor(l.fields);
      for (const key of Object.keys(acc)) {
        for (const direction of ['asc', 'desc'] as const) {
          const sorted = sortItems(l.rows, acc, { key, direction });
          expect({ list: l.name, key, n: sorted.length }).toEqual({ list: l.name, key, n: l.rows.length });
        }
      }
    }
  });

  it('runs every operator, and a value from the data matches at least one row', () => {
    for (const l of lists) {
      for (const f of l.fields) {
        const v = sample(f, l.rows);
        if (v === undefined) continue;
        for (const op of OPERATORS[f.kind]) {
          const out = applyConditions(l.rows, l.fields, [conditionFor(f, op, v)]);
          expect(out.length).toBeLessThanOrEqual(l.rows.length);
          const inclusive = ['any_of', 'contains', 'starts_with', 'eq', 'gte', 'lte', 'between', 'on', 'on_or_before', 'on_or_after', 'not_empty'];
          if (inclusive.includes(op)) expect({ list: l.name, field: f.key, op, matched: out.length > 0 }).toMatchObject({ matched: true });
        }
      }
    }
  });

  it('offers every choice value that appears in the data', () => {
    for (const l of lists) {
      for (const f of l.fields.filter((x) => x.kind === 'choice')) {
        const offered = new Set((f.options ?? []).map((o) => o.value));
        for (const r of l.rows) {
          const v = f.get(r);
          for (const x of Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]) {
            expect({ list: l.name, field: f.key, value: x, offered: offered.has(String(x)) }).toMatchObject({ offered: true });
          }
        }
        for (const o of f.options ?? []) expect({ list: l.name, field: f.key, label: o.label.includes('.') && !o.label.includes(' ') }).toMatchObject({ label: false });
      }
    }
  });
});
