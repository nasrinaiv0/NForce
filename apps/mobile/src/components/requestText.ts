import { formatDuration } from '@nforce/core';

import type { ApprovalItem, MyRequest } from '@/data/types';
import type { I18n } from '@/i18n';

/** Localized headline + detail for each request kind. */
export function describeRequest(item: ApprovalItem, i18n: I18n): { summary: string; detail: string } {
  const p = item.payload;
  const range = (a: string, b: string) => (a === b ? i18n.date(a as never) : `${i18n.date(a as never)} – ${i18n.date(b as never)}`);
  switch (p.kind) {
    case 'leave':
      return { summary: i18n.t('approvals.leaveSummary', { type: p.leaveType, days: i18n.plural('timeoff.days', p.days) }), detail: range(p.start, p.end) };
    case 'day_off':
      return { summary: i18n.t('approvals.leaveSummary', { type: i18n.t('timeoff.kind.day_off'), days: i18n.plural('timeoff.days', p.days) }), detail: range(p.start, p.end) + (p.note !== undefined ? ` · ${p.note}` : '') };
    case 'overtime':
      return { summary: i18n.t('approvals.overtimeSummary', { time: formatDuration(p.minutes) }), detail: `${i18n.date(p.date)} · ${p.reason}` };
    case 'timesheet':
      return {
        summary: i18n.t('approvals.timesheetSummary', { hours: formatDuration(p.minutes) }),
        detail: `${i18n.t('approvals.weekOf', { date: i18n.date(p.periodStart, { month: 'short', day: 'numeric' }) })} · ${i18n.t('pay.overtime')} ${formatDuration(p.overtimeMinutes)}`,
      };
    case 'correction':
      return { summary: i18n.t('approvals.missedClockOut'), detail: `${i18n.date(p.date)} · ${p.note}` };
  }
}


/** Title, subtitle and start date of one of the viewer's own requests. */
export function requestTitle(r: MyRequest, i18n: I18n): { title: string; subtitle: string; start: string } {
  const p = r.payload;
  switch (p.kind) {
    case 'leave':
    case 'day_off': {
      const dates = p.start === p.end ? i18n.date(p.start) : `${i18n.date(p.start)} – ${i18n.date(p.end)}`;
      return { title: p.kind === 'leave' ? p.leaveType : i18n.t('timeoff.kind.day_off'), subtitle: `${dates} · ${i18n.plural('timeoff.days', p.days)}`, start: p.start };
    }
    case 'overtime':
      return { title: i18n.t('approvals.kind.overtime'), subtitle: `${i18n.date(p.date)} · ${formatDuration(p.minutes)}`, start: p.date };
    case 'timesheet':
      return { title: i18n.t('approvals.kind.timesheet'), subtitle: i18n.t('approvals.weekOf', { date: i18n.date(p.periodStart) }), start: p.periodStart };
    case 'correction':
      return { title: i18n.t('approvals.kind.correction'), subtitle: i18n.date(p.date), start: p.date };
  }
}
