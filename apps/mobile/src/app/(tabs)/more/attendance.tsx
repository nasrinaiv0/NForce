import { addDays, formatDuration, queryList, toCsv, type SortSpec } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { HBarList, Heatmap, LineChart } from '@/components/Charts';
import { AttendanceKpis, hours, pct } from '@/components/ReportKit';
import { SegmentedControl } from '@/components/Controls';
import { DataTable, type Column } from '@/components/DataTable';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { Icon } from '@/components/Icon';
import { FilterChips, SortButton } from '@/components/ListToolbar';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListSection, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useAttendanceReport, useSession } from '@/data/queries';
import type { AttendanceFlag, AttendanceReport, ReportScope } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';
import { exportCsv } from '@/lib/exportCsv';

const FLAG_TONE: Readonly<Record<AttendanceFlag['kind'], Tone>> = { late: 'warning', absent: 'danger', missed_punch: 'danger' };
type PersonRow = AttendanceReport['people'][number];
type SortKey = 'name' | 'attendance' | 'punctuality' | 'late' | 'worked' | 'overtime';

export default function AttendanceScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const session = useSession();
  // Open on the widest view the person has: org for owners/executives, team for leads.
  const defaultScope: ReportScope = session.data?.reports.organization === true ? 'org' : session.data?.modules.includes('team') === true ? 'team' : 'me';
  const [picked, setScope] = useState<ReportScope | undefined>(undefined);
  const scope = picked ?? defaultScope;
  const [weeks, setWeeks] = useState(4);
  const report = useAttendanceReport(scope, weeks);
  const r = report.data;

  return (
    <Screen onRefresh={() => report.refetch()} maxWidth={1320}>
      {r !== undefined && r.availableScopes.length > 1 && (
        <SegmentedControl<ReportScope>
          segments={r.availableScopes.map((s) => ({ value: s, label: i18n.t(`reports.scope.${s}`) }))}
          value={scope}
          onChange={setScope}
        />
      )}
      <View style={styles.rowBetween}>
        <FilterChips
          options={[1, 4, 8].map((w) => ({ value: String(w), label: i18n.plural('reports.weeks', w) }))}
          value={String(weeks)}
          onChange={(v) => setWeeks(Number(v))}
        />
      </View>
      {report.isError ? (
        <ErrorState onRetry={() => void report.refetch()} message={errorMessage(report.error, i18n.t('common.errorBody'))} />
      ) : r === undefined ? (
        <LoadingBlock rows={4} height={110} />
      ) : (
        <>
          <Text variant="footnote" color="textSecondary">
            {i18n.t('reports.period', { from: i18n.date(r.from, { month: 'short', day: 'numeric' }), to: i18n.date(r.to, { month: 'short', day: 'numeric' }) })} ·{' '}
            {i18n.t('reports.vsPrevious')}
          </Text>
          {!r.personLevel && (
            <Card style={[styles.note, { backgroundColor: t.colors.infoContainer }]}>
              <Icon name="shield" size={18} color={t.colors.info} />
              <Text variant="footnote" style={{ flex: 1 }}>
                {i18n.t('reports.aggregatesOnly')}
              </Text>
            </Card>
          )}
          <AttendanceKpis m={r.metrics} prev={r.previous} i18n={i18n} />

          <View style={[isDesktop && styles.columns, { gap: t.space.xxl }]}>
            <Card style={[styles.flex, { gap: t.space.md }]}>
              <SectionHeader title={i18n.t('reports.trend')} />
              <LineChart
                title={i18n.t('reports.trend')}
                labels={r.trend.map((p) => i18n.date(p.weekStart, { month: 'short', day: 'numeric' }))}
                series={[
                  { name: i18n.t('reports.attendanceRate'), values: r.trend.map((p) => p.metrics.attendanceRate) },
                  { name: i18n.t('reports.punctuality'), values: r.trend.map((p) => p.metrics.punctualityRate) },
                ]}
                format={(v) => pct(i18n, v)}
                max={1}
                target={{ value: 0.95, label: i18n.t('reports.target', { value: '95%' }) }}
              />
            </Card>
            <Card style={[styles.flex, { gap: t.space.md }]}>
              <SectionHeader title={i18n.t('reports.daily')} />
              <Heatmap
                days={r.daily}
                weekdayLabels={Array.from({ length: 7 }, (_, i) => i18n.date(addDays('2024-01-01', i), { weekday: 'narrow' }))}
                format={(v) => pct(i18n, v)}
                dateLabel={(d) => i18n.date(d as never, { weekday: 'short', month: 'short', day: 'numeric' })}
              />
            </Card>
          </View>

          {r.groups.length > 0 && (
            <Card style={{ gap: t.space.lg }}>
              <SectionHeader title={i18n.t('reports.byTeam')} />
              <HBarList
                rows={[...r.groups].sort((a, b) => a.metrics.attendanceRate - b.metrics.attendanceRate).map((g) => ({
                  label: g.name,
                  sublabel: i18n.t('reports.punctualityShort', { value: pct(i18n, g.metrics.punctualityRate) }),
                  value: g.metrics.attendanceRate,
                  flag: g.metrics.attendanceRate < 0.95 ? <Pill label={i18n.t('reports.belowTarget')} tone="warning" icon="warning" /> : undefined,
                }))}
                format={(v) => pct(i18n, v)}
                target={0.95}
              />
            </Card>
          )}

          {r.people.length > 0 && <PeopleBreakdown report={r} i18n={i18n} isDesktop={isDesktop} />}
          {r.exceptions.length > 0 && <Exceptions report={r} i18n={i18n} />}
        </>
      )}
    </Screen>
  );
}

function PeopleBreakdown({ report, i18n, isDesktop }: { report: AttendanceReport; i18n: I18n; isDesktop: boolean }) {
  const t = useTheme();
  const [sort, setSort] = useState<SortSpec<SortKey>>({ key: 'attendance', direction: 'asc' });
  const rows = useMemo(
    () =>
      queryList(report.people, {
        sort,
        locale: i18n.tag,
        accessors: {
          name: (p) => p.person.name,
          attendance: (p) => p.metrics.attendanceRate,
          punctuality: (p) => p.metrics.punctualityRate,
          late: (p) => p.metrics.lateDays,
          worked: (p) => p.metrics.workedMinutes,
          overtime: (p) => p.metrics.overtimeMinutes,
        },
      }),
    [report.people, sort, i18n.tag],
  );
  const download = () =>
    void exportCsv(
      `nforce-attendance-${report.from}-${report.to}.csv`,
      toCsv(rows, [
        { header: i18n.t('team.col.person'), value: (p) => p.person.name },
        { header: i18n.t('team.col.team'), value: (p) => p.teamName ?? '' },
        { header: i18n.t('reports.attendanceRate'), value: (p) => Math.round(p.metrics.attendanceRate * 1000) / 10 },
        { header: i18n.t('reports.punctuality'), value: (p) => Math.round(p.metrics.punctualityRate * 1000) / 10 },
        { header: i18n.t('reports.absences'), value: (p) => p.metrics.absentDays },
        { header: i18n.t('reports.lateArrivals'), value: (p) => p.metrics.lateDays },
        { header: i18n.t('reports.workedHours'), value: (p) => Math.round(p.metrics.workedMinutes / 6) / 10 },
        { header: i18n.t('pay.overtime'), value: (p) => Math.round(p.metrics.overtimeMinutes / 6) / 10 },
        { header: i18n.t('pay.night'), value: (p) => Math.round(p.metrics.nightMinutes / 6) / 10 },
      ], { bom: true }),
    );
  const open = (p: PersonRow) => router.push({ pathname: '/more/timesheets', params: { user: p.person.id } });
  const columns: Column<PersonRow, SortKey>[] = [
    {
      key: 'name',
      title: i18n.t('team.col.person'),
      flex: 2.4,
      sortKey: 'name',
      render: (p) => (
        <View style={styles.person}>
          <Avatar initials={p.person.initials} hue={p.person.hue} size={30} />
          <View style={styles.flex}>
            <Text variant="subhead" weight="600" numberOfLines={1}>
              {p.person.name}
            </Text>
            <Text variant="caption" color="textSecondary" numberOfLines={1}>
              {p.teamName ?? p.person.title}
            </Text>
          </View>
        </View>
      ),
    },
    { key: 'att', title: i18n.t('reports.attendanceRate'), flex: 1.1, align: 'right', sortKey: 'attendance', render: (p) => <Text variant="footnote" tabular weight="600" color={p.metrics.attendanceRate < 0.95 ? 'warning' : 'text'}>{pct(i18n, p.metrics.attendanceRate)}</Text> },
    { key: 'pun', title: i18n.t('reports.punctuality'), flex: 1.1, align: 'right', sortKey: 'punctuality', render: (p) => <Text variant="footnote" tabular>{pct(i18n, p.metrics.punctualityRate)}</Text> },
    { key: 'abs', title: i18n.t('reports.absences'), flex: 0.9, align: 'right', render: (p) => <Text variant="footnote" tabular>{p.metrics.absentDays}</Text> },
    { key: 'late', title: i18n.t('reports.lateArrivals'), flex: 0.9, align: 'right', sortKey: 'late', render: (p) => <Text variant="footnote" tabular>{p.metrics.lateDays}</Text> },
    { key: 'worked', title: i18n.t('reports.workedHours'), flex: 1, align: 'right', sortKey: 'worked', render: (p) => <Text variant="footnote" tabular>{hours(p.metrics.workedMinutes)}</Text> },
    { key: 'ot', title: i18n.t('team.col.overtime'), flex: 0.9, align: 'right', sortKey: 'overtime', render: (p) => <Text variant="footnote" tabular>{hours(p.metrics.overtimeMinutes)}</Text> },
    { key: 'nd', title: i18n.t('team.col.night'), flex: 0.9, align: 'right', render: (p) => <Text variant="footnote" tabular>{hours(p.metrics.nightMinutes)}</Text> },
  ];
  return (
    <View style={{ gap: t.space.md }}>
      <View style={styles.rowBetween}>
        <SectionHeader title={i18n.t('reports.byPerson')} />
        <View style={styles.row}>
          <SortButton
            options={[
              { key: 'attendance', label: i18n.t('reports.attendanceRate') },
              { key: 'punctuality', label: i18n.t('reports.punctuality') },
              { key: 'late', label: i18n.t('reports.lateArrivals'), defaultDirection: 'desc' },
              { key: 'overtime', label: i18n.t('pay.overtime'), defaultDirection: 'desc' },
              { key: 'worked', label: i18n.t('reports.workedHours'), defaultDirection: 'desc' },
              { key: 'name', label: i18n.t('team.sort.name') },
            ]}
            value={sort}
            onChange={setSort}
          />
          <Button title={i18n.t('reports.exportCsv')} icon="download" size="small" variant="tonal" onPress={download} />
        </View>
      </View>
      {isDesktop ? (
        <DataTable columns={columns} rows={rows} rowKey={(p) => p.person.id} sort={sort} onSort={setSort} onRowPress={open} rowLabel={(p) => `${p.person.name}, ${pct(i18n, p.metrics.attendanceRate)}`} />
      ) : (
        <ListSection>
          {rows.map((p, idx) => (
            <Touchable key={p.person.id} onPress={() => open(p)} feedback="highlight" accessibilityLabel={`${p.person.name}, ${pct(i18n, p.metrics.attendanceRate)}`}>
              <View style={[styles.mobileRow, { paddingHorizontal: t.space.lg }, idx < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
                <Avatar initials={p.person.initials} hue={p.person.hue} size={36} />
                <View style={styles.flex}>
                  <Text variant="body" weight="600" numberOfLines={1}>
                    {p.person.name}
                  </Text>
                  <Text variant="caption" color="textSecondary">
                    {i18n.t('reports.personLine', { late: p.metrics.lateDays, absent: p.metrics.absentDays, ot: hours(p.metrics.overtimeMinutes) })}
                  </Text>
                </View>
                <Text variant="subhead" tabular weight="600" color={p.metrics.attendanceRate < 0.95 ? 'warning' : 'text'}>
                  {pct(i18n, p.metrics.attendanceRate)}
                </Text>
              </View>
            </Touchable>
          ))}
        </ListSection>
      )}
    </View>
  );
}

function Exceptions({ report, i18n }: { report: AttendanceReport; i18n: I18n }) {
  const t = useTheme();
  const [kind, setKind] = useState<'all' | AttendanceFlag['kind']>('all');
  const rows = report.exceptions.filter((e) => kind === 'all' || e.kind === kind);
  const count = (k: AttendanceFlag['kind']) => report.exceptions.filter((e) => e.kind === k).length;
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('reports.exceptions')} />
      <FilterChips
        options={[
          { value: 'all', label: i18n.t('list.all'), count: report.exceptions.length },
          { value: 'late', label: i18n.t('reports.flag.late'), count: count('late') },
          { value: 'absent', label: i18n.t('reports.flag.absent'), count: count('absent') },
          { value: 'missed_punch', label: i18n.t('reports.flag.missed_punch'), count: count('missed_punch') },
        ]}
        value={kind}
        onChange={setKind}
      />
      {rows.length === 0 ? (
        <EmptyState icon="checkCircle" title={i18n.t('list.noMatches')} />
      ) : (
        <ListSection>
          {rows.map((e, idx) => (
            <View key={`${e.person.id}-${e.date}-${e.kind}`} style={[styles.mobileRow, { paddingHorizontal: t.space.lg }, idx < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
              {report.scope !== 'me' && <Avatar initials={e.person.initials} hue={e.person.hue} size={32} />}
              <View style={styles.flex}>
                <Text variant="subhead" weight="600">
                  {report.scope === 'me' ? i18n.date(e.date, { weekday: 'long', month: 'short', day: 'numeric' }) : e.person.name}
                </Text>
                {report.scope !== 'me' && (
                  <Text variant="caption" color="textSecondary">
                    {i18n.date(e.date, { weekday: 'short', month: 'short', day: 'numeric' })}
                  </Text>
                )}
              </View>
              <Pill label={e.kind === 'late' && e.minutes !== undefined ? i18n.t('team.lateBy', { time: formatDuration(e.minutes) }) : i18n.t(`reports.flag.${e.kind}`)} tone={FLAG_TONE[e.kind]} />
            </View>
          ))}
        </ListSection>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  columns: { flexDirection: 'row', alignItems: 'stretch' },
  flex: { flex: 1 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' },
  note: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  person: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  mobileRow: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 60, paddingVertical: 10 },
});
