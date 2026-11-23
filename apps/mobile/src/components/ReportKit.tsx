import { formatDuration, type AttendanceMetrics } from '@nforce/core';
import { StyleSheet, View } from 'react-native';

import { useTheme } from '@/design/theme';
import type { I18n } from '@/i18n';
import { KpiTile } from './Charts';

/** Shared formatting and KPI blocks for Attendance and Reports. */
export const pct = (i18n: I18n, v: number) => i18n.number(v, { style: 'percent', maximumFractionDigits: 1 });
export const hours = (min: number) => formatDuration(min);
/** "+1.2 pts" style change between two rates. */
export function rateDelta(i18n: I18n, cur: number, prev: number) {
  const d = (cur - prev) * 100;
  return { text: i18n.t('reports.pts', { value: `${d >= 0 ? '+' : ''}${i18n.number(d, { maximumFractionDigits: 1 })}` }), direction: Math.abs(d) < 0.05 ? ('flat' as const) : d > 0 ? ('up' as const) : ('down' as const) };
}
export function countDelta(i18n: I18n, cur: number, prev: number, fmt: (n: number) => string = (n) => i18n.number(n)) {
  const d = cur - prev;
  return { text: `${d >= 0 ? '+' : '−'}${fmt(Math.abs(d))}`, direction: d === 0 ? ('flat' as const) : d > 0 ? ('up' as const) : ('down' as const) };
}

/** KPI grid shared by Attendance and Reports. */
export function AttendanceKpis({ m, prev, i18n }: { m: AttendanceMetrics; prev: AttendanceMetrics; i18n: I18n }) {
  const t = useTheme();
  return (
    <View style={[styles.kpis, { gap: t.space.md }]}>
      <KpiTile label={i18n.t('reports.attendanceRate')} value={pct(i18n, m.attendanceRate)} delta={rateDelta(i18n, m.attendanceRate, prev.attendanceRate)} better="up" />
      <KpiTile label={i18n.t('reports.punctuality')} value={pct(i18n, m.punctualityRate)} delta={rateDelta(i18n, m.punctualityRate, prev.punctualityRate)} better="up" />
      <KpiTile label={i18n.t('reports.absences')} value={i18n.number(m.absentDays)} delta={countDelta(i18n, m.absentDays, prev.absentDays)} better="down" hint={i18n.t('reports.leaveDays', { count: i18n.number(m.leaveDays) })} />
      <KpiTile label={i18n.t('reports.lateArrivals')} value={i18n.number(m.lateDays)} delta={countDelta(i18n, m.lateDays, prev.lateDays)} better="down" hint={m.lateDays > 0 ? i18n.t('reports.avgLate', { time: formatDuration(Math.round(m.averageLateMinutes)) }) : undefined} />
      <KpiTile label={i18n.t('reports.workedHours')} value={hours(m.workedMinutes)} hint={i18n.t('reports.perDay', { time: formatDuration(Math.round(m.averageWorkedPerPresentDay)) })} />
      <KpiTile label={i18n.t('pay.overtime')} value={hours(m.overtimeMinutes)} delta={countDelta(i18n, m.overtimeMinutes, prev.overtimeMinutes, formatDuration)} better="down" hint={i18n.t('reports.ofWorked', { value: pct(i18n, m.overtimeShare) })} />
      <KpiTile label={i18n.t('pay.night')} value={hours(m.nightMinutes)} />
      <KpiTile label={i18n.t('reports.missedPunches')} value={i18n.number(m.missedPunches)} better="down" delta={countDelta(i18n, m.missedPunches, prev.missedPunches)} />
    </View>
  );
}


const styles = StyleSheet.create({
  kpis: { flexDirection: 'row', flexWrap: 'wrap' },
});
