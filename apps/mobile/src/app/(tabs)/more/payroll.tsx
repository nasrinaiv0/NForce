import { addDays, formatDuration, queryList, toCsv, type DateKey, type PayrollFlag, type PayrollRow, type SortSpec } from '@nforce/core';
import { useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { KpiTile } from '@/components/Charts';
import { DataTable, type Column } from '@/components/DataTable';
import { Pill, type Tone } from '@/components/Display';
import { Icon } from '@/components/Icon';
import { FilterChips, SortButton } from '@/components/ListToolbar';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useLockPayroll, usePayroll } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n } from '@/i18n';
import { exportCsv } from '@/lib/exportCsv';

const FLAG_TONE: Readonly<Record<PayrollFlag, Tone>> = { timesheet_not_approved: 'danger', missed_punch: 'danger', unapproved_overtime: 'warning' };
type Filter = 'all' | 'blocked' | 'clear';
type SortKey = 'name' | 'payable' | 'weighted' | 'unapproved';

/** Payroll preparation: approved hours by pay code, blockers, export and period lock. */
export default function PayrollScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const [period, setPeriod] = useState<DateKey | undefined>(undefined);
  const payroll = usePayroll(period);
  const lock = useLockPayroll();
  const [filter, setFilter] = useState<Filter>('all');
  const [sort, setSort] = useState<SortSpec<SortKey>>({ key: 'name', direction: 'asc' });
  const p = payroll.data;
  const blocked = (r: PayrollRow) => r.flags.includes('timesheet_not_approved') || r.flags.includes('missed_punch');
  const rows = useMemo(
    () =>
      queryList(p?.rows ?? [], {
        filters: filter === 'all' ? [] : [(r) => (filter === 'blocked' ? blocked(r) : !blocked(r))],
        sort,
        locale: i18n.tag,
        accessors: { name: (r) => r.name, payable: (r) => r.payableMinutes, weighted: (r) => r.weightedMinutes, unapproved: (r) => r.unapprovedOvertimeMinutes },
      }),
    [p?.rows, filter, sort, i18n.tag],
  );

  if (payroll.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void payroll.refetch()} message={errorMessage(payroll.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (p === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={90} />
      </Screen>
    );
  }
  const codeMinutes = (r: PayrollRow, code: string) => r.lines.find((l) => l.code === code)?.minutes ?? 0;
  const download = () =>
    void exportCsv(
      `nforce-payroll-${p.periodStart}.csv`,
      toCsv(p.rows, [
        { header: i18n.t('team.col.person'), value: (r) => r.name },
        ...p.codes.map((code) => ({ header: `${code} (h)`, value: (r: PayrollRow) => Math.round(codeMinutes(r, code) / 6) / 10 })),
        { header: i18n.t('payroll.payableHours'), value: (r) => Math.round(r.payableMinutes / 6) / 10 },
        { header: i18n.t('timesheet.paidEquivalent'), value: (r) => Math.round(r.weightedMinutes / 6) / 10 },
        { header: i18n.t('payroll.unapprovedOt'), value: (r) => Math.round(r.unapprovedOvertimeMinutes / 6) / 10 },
        { header: i18n.t('payroll.flags'), value: (r) => r.flags.map((f) => i18n.t(`payroll.flag.${f}`)).join('; ') },
      ], { bom: true }),
    );

  const columns: Column<PayrollRow, SortKey>[] = [
    { key: 'name', title: i18n.t('team.col.person'), flex: 2, sortKey: 'name', render: (r) => <Text variant="subhead" weight="600" numberOfLines={1}>{r.name}</Text> },
    ...p.codes.map((code) => ({ key: code, title: code, flex: 0.9, align: 'right' as const, render: (r: PayrollRow) => <Text variant="footnote" tabular color={codeMinutes(r, code) === 0 ? 'textTertiary' : 'text'}>{formatDuration(codeMinutes(r, code))}</Text> })),
    { key: 'payable', title: i18n.t('payroll.payable'), flex: 1, align: 'right', sortKey: 'payable', render: (r) => <Text variant="footnote" tabular weight="600">{formatDuration(r.payableMinutes)}</Text> },
    { key: 'weighted', title: i18n.t('payroll.weighted'), flex: 1, align: 'right', sortKey: 'weighted', render: (r) => <Text variant="footnote" tabular>{formatDuration(r.weightedMinutes)}</Text> },
    { key: 'flags', title: i18n.t('payroll.flags'), flex: 2, render: (r) => <View style={styles.flags}>{r.flags.map((f) => <Pill key={f} label={i18n.t(`payroll.flag.${f}`)} tone={FLAG_TONE[f]} />)}</View> },
  ];

  return (
    <Screen onRefresh={() => payroll.refetch()} maxWidth={1400}>
      <View style={styles.rowBetween}>
        <View style={styles.row}>
          <Touchable onPress={() => setPeriod(addDays(p.periodStart, -7))} feedback="highlight" accessibilityLabel={i18n.t('timesheet.prevPeriod')} style={[styles.nav, { backgroundColor: t.colors.fill }]}>
            <View style={{ transform: [{ scaleX: -1 }] }}>
              <Icon name="chevron" size={14} color={t.colors.primary} />
            </View>
          </Touchable>
          <Text variant="headline" tabular>
            {i18n.date(p.periodStart, { month: 'short', day: 'numeric' })} – {i18n.date(p.periodEnd, { month: 'short', day: 'numeric' })}
          </Text>
          <Touchable onPress={() => setPeriod(addDays(p.periodStart, 7))} feedback="highlight" accessibilityLabel={i18n.t('timesheet.nextPeriod')} style={[styles.nav, { backgroundColor: t.colors.fill }]}>
            <Icon name="chevron" size={14} color={t.colors.primary} />
          </Touchable>
        </View>
        <Pill label={p.locked ? i18n.t('payroll.locked') : p.ready ? i18n.t('payroll.ready') : i18n.plural('payroll.blocked', p.blockers)} tone={p.locked ? 'primary' : p.ready ? 'success' : 'warning'} icon={p.locked ? 'lock' : undefined} dot={!p.locked} />
      </View>
      <View style={[styles.kpis, { gap: t.space.md }]}>
        <KpiTile label={i18n.t('payroll.employees')} value={i18n.number(p.rows.length)} />
        <KpiTile label={i18n.t('payroll.payableHours')} value={formatDuration(p.totals.payableMinutes)} />
        <KpiTile label={i18n.t('timesheet.paidEquivalent')} value={formatDuration(p.totals.weightedMinutes)} hint={i18n.t('timesheet.paidEquivalentHint')} />
        <KpiTile label={i18n.t('payroll.unapprovedOt')} value={formatDuration(p.totals.unapprovedOvertimeMinutes)} hint={i18n.t('payroll.unapprovedHint')} />
      </View>
      {!p.locked && !p.ready && (
        <Card style={[styles.row, { backgroundColor: t.colors.warningContainer }]}>
          <Icon name="warning" size={18} color={t.colors.warning} />
          <Text variant="footnote" style={{ flex: 1, color: t.colors.warning }}>
            {i18n.t('payroll.blockedHint')}
          </Text>
        </Card>
      )}
      <View style={styles.rowBetween}>
        <FilterChips
          options={[
            { value: 'all', label: i18n.t('list.all'), count: p.rows.length },
            { value: 'blocked', label: i18n.t('payroll.filter.blocked'), count: p.rows.filter(blocked).length },
            { value: 'clear', label: i18n.t('payroll.filter.clear'), count: p.rows.filter((r) => !blocked(r)).length },
          ]}
          value={filter}
          onChange={setFilter}
        />
        <View style={styles.row}>
          <SortButton
            options={[
              { key: 'name', label: i18n.t('team.sort.name') },
              { key: 'payable', label: i18n.t('payroll.payableHours'), defaultDirection: 'desc' },
              { key: 'weighted', label: i18n.t('timesheet.paidEquivalent'), defaultDirection: 'desc' },
              { key: 'unapproved', label: i18n.t('payroll.unapprovedOt'), defaultDirection: 'desc' },
            ]}
            value={sort}
            onChange={setSort}
          />
          <Button title={i18n.t('reports.exportCsv')} icon="download" size="small" variant="tonal" onPress={download} />
          {!p.locked && (
            <Button
              title={i18n.t('payroll.lock')}
              icon="lock"
              size="small"
              disabled={!p.canLock}
              loading={lock.isPending}
              onPress={() => lock.mutate(p.periodStart, { onSuccess: () => haptics.success(), onError: () => haptics.error() })}
            />
          )}
        </View>
      </View>
      {lock.isError && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {errorMessage(lock.error, i18n.t('common.errorBody'))}
        </Text>
      )}
      {isDesktop ? (
        <DataTable columns={columns} rows={rows} rowKey={(r) => r.userId} sort={sort} onSort={setSort} />
      ) : (
        <ListSection footer={i18n.t('payroll.footer')}>
          {rows.map((r, idx) => (
            <View key={r.userId} style={[styles.mobileRow, { paddingHorizontal: t.space.lg }, idx < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
              <View style={{ flex: 1, gap: 4 }}>
                <Text variant="body" weight="600">
                  {r.name}
                </Text>
                <Text variant="caption" color="textSecondary">
                  {r.lines.map((l) => `${l.code} ${formatDuration(l.minutes)}`).join(' · ')}
                </Text>
                {r.flags.length > 0 && (
                  <View style={styles.flags}>
                    {r.flags.map((f) => (
                      <Pill key={f} label={i18n.t(`payroll.flag.${f}`)} tone={FLAG_TONE[f]} />
                    ))}
                  </View>
                )}
              </View>
              <Text variant="subhead" tabular weight="600">
                {formatDuration(r.payableMinutes)}
              </Text>
            </View>
          ))}
        </ListSection>
      )}
      <Text variant="caption" color="textTertiary">
        {i18n.t('payroll.disclaimer')}
      </Text>
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' },
  kpis: { flexDirection: 'row', flexWrap: 'wrap' },
  nav: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
  flags: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  mobileRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12 },
});
