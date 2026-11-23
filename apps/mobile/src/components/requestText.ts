import { formatDuration } from '@nforce/core';

import type { ApprovalItem } from '@/data/types';
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

