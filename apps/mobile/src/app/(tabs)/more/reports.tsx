import { formatDuration, toCsv } from '@nforce/core';
import { router } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { BarChart, HBarList, KpiTile, LineChart } from '@/components/Charts';
import { Meter, Pill } from '@/components/Display';
import { Icon, type IconName } from '@/components/Icon';
import { FilterChips } from '@/components/ListToolbar';
import { PayLinesList } from '@/components/PayBreakdown';
import { AttendanceKpis, countDelta, hours, pct, rateDelta } from '@/components/ReportKit';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useAttendanceReport, useExecutiveReport, useSession, useTimesheet } from '@/data/queries';
import type { ExecutiveReport } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';
import { exportCsv } from '@/lib/exportCsv';

const RISK_ICON: Readonly<Record<ExecutiveReport['risks'][number]['key'], IconName>> = {
  low_attendance: 'attendance',
  high_overtime: 'overtime',
  late_trend: 'trend',
  approvals_overdue: 'approvals',
  missed_punches: 'warning',
};

export default function ReportsScreen() {
  const session = useSession();
  if (session.data === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={110} />
      </Screen>
    );
  }
  return session.data.reports.executive ? <ExecutiveDashboard /> : <PersonalReport />;
}

function ExecutiveDashboard() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const [weeks, setWeeks] = useState(4);
  const report = useExecutiveReport(weeks);
  const r = report.data;

  if (report.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void report.refetch()} message={errorMessage(report.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (r === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={5} height={110} />
      </Screen>
    );
  }

  const weekLabels = r.trend.map((p) => i18n.date(p.weekStart, { month: 'short', day: 'numeric' }));
  const download = () =>
    void exportCsv(
      `nforce-executive-${r.from}-${r.to}.csv`,
      toCsv(r.teams, [
        { header: i18n.t('team.col.team'), value: (x) => x.name },
        { header: i18n.t('reports.headcount'), value: (x) => x.headcount },
        { header: i18n.t('reports.attendanceRate'), value: (x) => Math.round(x.metrics.attendanceRate * 1000) / 10 },
        { header: i18n.t('reports.punctuality'), value: (x) => Math.round(x.metrics.punctualityRate * 1000) / 10 },
        { header: i18n.t('reports.absences'), value: (x) => x.metrics.absentDays },
        { header: i18n.t('reports.workedHours'), value: (x) => Math.round(x.metrics.workedMinutes / 6) / 10 },
        { header: i18n.t('pay.overtime'), value: (x) => Math.round(x.metrics.overtimeMinutes / 6) / 10 },
        { header: i18n.t('pay.night'), value: (x) => Math.round(x.metrics.nightMinutes / 6) / 10 },
      ], { bom: true }),
    );

  const left = (
    <View style={{ gap: t.space.xxl }}>
      <Card style={{ gap: t.space.md }}>
        <SectionHeader title={i18n.t('reports.trend')} />
        <LineChart
          title={i18n.t('reports.trend')}
          labels={weekLabels}
          series={[
            { name: i18n.t('reports.attendanceRate'), values: r.trend.map((p) => p.metrics.attendanceRate) },
            { name: i18n.t('reports.punctuality'), values: r.trend.map((p) => p.metrics.punctualityRate) },
          ]}
          format={(v) => pct(i18n, v)}
          max={1}
          target={{ value: 0.95, label: i18n.t('reports.target', { value: '95%' }) }}
        />
      </Card>
      <Card style={{ gap: t.space.md }}>
        <SectionHeader title={i18n.t('reports.overtimeTrend')} />
        <BarChart title={i18n.t('reports.overtimeTrend')} labels={weekLabels} values={r.trend.map((p) => p.metrics.overtimeMinutes / 60)} format={(v) => formatDuration(Math.round(v * 60))} />
      </Card>
      <Card style={{ gap: t.space.lg }}>
        <SectionHeader title={i18n.t('reports.laborMix')} />
        <PayLinesList lines={r.laborMix} i18n={i18n} emptyLabel={i18n.t('timesheet.noEntries')} />
        <Text variant="footnote" color="textSecondary">
          {i18n.t('reports.weightedNote', { time: hours(r.weightedMinutes) })}
        </Text>
      </Card>
    </View>
  );

  const right = (
    <View style={{ gap: t.space.xxl }}>
      <Card style={{ gap: t.space.md }}>
        <SectionHeader title={i18n.t('reports.insights')} />
        {r.risks.length === 0 ? (
          <View style={styles.row}>
            <Icon name="checkCircle" size={18} color={t.colors.success} />
            <Text variant="subhead">{i18n.t('reports.noRisks')}</Text>
          </View>
        ) : (
          r.risks.map((k, i) => (
            <View key={`${k.key}-${i}`} style={styles.risk}>
              <View style={[styles.riskIcon, { backgroundColor: t.colors.warningContainer }]}>
                <Icon name={RISK_ICON[k.key]} size={16} color={t.colors.warning} />
              </View>
              <Text variant="subhead" style={styles.flex}>
                {riskText(k, i18n)}
              </Text>
            </View>
          ))
        )}
      </Card>
      <Card style={{ gap: t.space.lg }}>
        <SectionHeader title={i18n.t('reports.byTeam')} />
        <HBarList
          rows={[...r.teams].sort((a, b) => a.metrics.attendanceRate - b.metrics.attendanceRate).map((x) => ({
            label: x.name,
            sublabel: i18n.t('reports.teamLine', { count: x.headcount, ot: hours(x.metrics.overtimeMinutes), nd: hours(x.metrics.nightMinutes) }),
            value: x.metrics.attendanceRate,
            flag: x.metrics.attendanceRate < 0.95 ? <Pill label={i18n.t('reports.belowTarget')} tone="warning" icon="warning" /> : undefined,
          }))}
          format={(v) => pct(i18n, v)}
          target={0.95}
        />
      </Card>
      <Card style={{ gap: t.space.md }}>
        <SectionHeader title={i18n.t('reports.approvalsSla')} />
        <View style={[styles.kpis, { gap: t.space.md }]}>
          <KpiTile label={i18n.t('reports.medianDecision')} value={i18n.t('reports.hoursShort', { value: i18n.number(r.approvals.medianHoursToDecide, { maximumFractionDigits: 1 }) })} hint={i18n.t('reports.p90', { value: i18n.number(r.approvals.p90HoursToDecide, { maximumFractionDigits: 1 }) })} />
          <KpiTile label={i18n.t('reports.pendingApprovals')} value={i18n.number(r.approvals.pending)} hint={i18n.t('reports.overdue', { count: r.approvals.overdue })} />
          <KpiTile label={i18n.t('reports.approvalRate')} value={pct(i18n, r.approvals.approvalRate)} />
        </View>
        <View style={styles.kindRow}>
          {r.approvals.byKind.map((k) => (
            <Pill key={k.kind} label={`${i18n.t(`approvals.kind.${k.kind as 'leave'}`)} · ${k.total}${k.pending > 0 ? ` (${k.pending} ${i18n.t('approvals.status.pending').toLowerCase()})` : ''}`} tone="neutral" />
          ))}
        </View>
      </Card>
      <Card style={{ gap: t.space.sm }}>
        <SectionHeader title={i18n.t('reports.leaveUtilization')} />
        <Meter value={(r.leave.entitled - r.leave.available) / Math.max(1, r.leave.entitled)} color={t.colors.primary} height={10} />
        <Text variant="footnote" color="textSecondary">
          {i18n.t('reports.leaveLine', {
            used: i18n.number(r.leave.entitled - r.leave.available),
            entitled: i18n.number(r.leave.entitled),
            taken: i18n.number(r.leave.takenDays),
          })}
        </Text>
      </Card>
      <Card style={{ gap: t.space.sm }} onPress={() => router.push('/more/payroll')} accessibilityLabel={i18n.t('reports.payrollReadiness')}>
        <View style={styles.rowBetween}>
          <SectionHeader title={i18n.t('reports.payrollReadiness')} />
          <Pill label={r.payroll.ready ? i18n.t('payroll.ready') : i18n.plural('payroll.blocked', r.payroll.blockers)} tone={r.payroll.ready ? 'success' : 'warning'} dot />
        </View>
        <Text variant="footnote" color="textSecondary">
          {i18n.t('reports.payrollLine', { period: i18n.date(r.payroll.periodStart, { month: 'short', day: 'numeric' }), time: hours(r.payroll.unapprovedOvertimeMinutes) })}
        </Text>
      </Card>
    </View>
  );

  return (
    <Screen onRefresh={() => report.refetch()} maxWidth={1360}>
      <View style={styles.rowBetween}>
        <View style={styles.flex}>
          <Text variant="title2">{i18n.t(`reports.scopeTitle.${r.scopeLabel}`)}</Text>
          <Text variant="footnote" color="textSecondary">
            {i18n.t('reports.period', { from: i18n.date(r.from, { month: 'short', day: 'numeric' }), to: i18n.date(r.to, { month: 'short', day: 'numeric' }) })} · {i18n.t('reports.vsPrevious')}
          </Text>
        </View>
        <Button title={i18n.t('reports.exportCsv')} icon="download" size="small" variant="tonal" onPress={download} />
      </View>
      <FilterChips options={[4, 8].map((w) => ({ value: String(w), label: i18n.plural('reports.weeks', w) }))} value={String(weeks)} onChange={(v) => setWeeks(Number(v))} />
      <View style={[styles.kpis, { gap: t.space.md }]}>
        <KpiTile label={i18n.t('reports.headcount')} value={i18n.number(r.current.headcount)} />
        <KpiTile label={i18n.t('reports.attendanceRate')} value={pct(i18n, r.current.attendanceRate)} delta={rateDelta(i18n, r.current.attendanceRate, r.previous.attendanceRate)} better="up" />
        <KpiTile label={i18n.t('reports.punctuality')} value={pct(i18n, r.current.punctualityRate)} delta={rateDelta(i18n, r.current.punctualityRate, r.previous.punctualityRate)} better="up" />
        <KpiTile label={i18n.t('reports.absenteeism')} value={pct(i18n, r.current.absenteeismRate)} delta={rateDelta(i18n, r.current.absenteeismRate, r.previous.absenteeismRate)} better="down" />
        <KpiTile label={i18n.t('pay.overtime')} value={hours(r.current.overtimeMinutes)} delta={countDelta(i18n, r.current.overtimeMinutes, r.previous.overtimeMinutes, formatDuration)} better="down" hint={i18n.t('reports.ofWorked', { value: pct(i18n, r.current.overtimeShare) })} />
        <KpiTile label={i18n.t('pay.night')} value={hours(r.current.nightMinutes)} />
        <KpiTile label={i18n.t('reports.workedHours')} value={hours(r.current.workedMinutes)} />
        <KpiTile label={i18n.t('timesheet.paidEquivalent')} value={hours(r.weightedMinutes)} hint={i18n.t('timesheet.paidEquivalentHint')} />
      </View>
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xxl }]}>
          <View style={{ flex: 1.15 }}>{left}</View>
          <View style={styles.flex}>{right}</View>
        </View>
      ) : (
        <>
          {right}
          {left}
        </>
      )}
      <Text variant="caption" color="textTertiary" align="center">
        {i18n.t('reports.privacyNote')}
      </Text>
    </Screen>
  );
}

function riskText(k: ExecutiveReport['risks'][number], i18n: I18n): string {
  switch (k.key) {
    case 'low_attendance':
      return i18n.t('reports.risk.low_attendance', { team: k.subject, value: pct(i18n, k.value) });
    case 'high_overtime':
      return i18n.t('reports.risk.high_overtime', { team: k.subject, value: pct(i18n, k.value) });
    case 'late_trend':
      return i18n.t('reports.risk.late_trend', { value: i18n.number(Math.abs(k.value) * 100, { maximumFractionDigits: 1 }) });
    case 'approvals_overdue':
      return i18n.t('reports.risk.approvals_overdue', { count: k.value });
    case 'missed_punches':
      return i18n.t('reports.risk.missed_punches', { count: k.value });
  }
}

/** Everyone gets a personal report: their attendance and latest pay categories. */
function PersonalReport() {
  const t = useTheme();
  const i18n = useI18n();
  const report = useAttendanceReport('me', 4);
  const sheet = useTimesheet();
  return (
    <Screen onRefresh={() => report.refetch()} maxWidth={1100}>
      <Text variant="title2">{i18n.t('reports.myReport')}</Text>
      {report.data === undefined ? (
        <LoadingBlock rows={3} height={100} />
      ) : (
        <>
          <AttendanceKpis m={report.data.metrics} prev={report.data.previous} i18n={i18n} />
          <Card style={{ gap: t.space.md }}>
            <SectionHeader title={i18n.t('reports.trend')} action={{ label: i18n.t('common.seeAll'), onPress: () => router.push('/more/attendance') }} />
            <LineChart
              title={i18n.t('reports.trend')}
              labels={report.data.trend.map((p) => i18n.date(p.weekStart, { month: 'short', day: 'numeric' }))}
              series={[
                { name: i18n.t('reports.attendanceRate'), values: report.data.trend.map((p) => p.metrics.attendanceRate) },
                { name: i18n.t('reports.punctuality'), values: report.data.trend.map((p) => p.metrics.punctualityRate) },
              ]}
              format={(v) => pct(i18n, v)}
              max={1}
            />
          </Card>
        </>
      )}
      {sheet.data !== undefined && (
        <Card style={{ gap: t.space.lg }} onPress={() => router.push('/more/timesheets')} accessibilityLabel={i18n.t('timesheet.breakdown')}>
          <SectionHeader title={`${i18n.t('timesheet.breakdown')} · ${i18n.date(sheet.data.periodStart, { month: 'short', day: 'numeric' })}`} />
          <PayLinesList lines={sheet.data.summary} i18n={i18n} emptyLabel={i18n.t('timesheet.noEntries')} />
        </Card>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  kpis: { flexDirection: 'row', flexWrap: 'wrap' },
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  flex: { flex: 1 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' },
  risk: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  riskIcon: { width: 30, height: 30, borderRadius: 15, alignItems: 'center', justifyContent: 'center' },
  kindRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
});
