import { formatDuration, weightedMinutes } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo } from 'react';
import { StyleSheet, View } from 'react-native';

import type { TimesheetDay, TimesheetView } from '@/data/types';
import { useTheme } from '@/design/theme';
import type { I18n } from '@/i18n';
import { Button } from './Button';
import { timesheetDayFields } from '@/data/listFields';

import { GridTable, NumCell, type GridColumn } from './GridTable';
import { ListControls, useListView } from './ListView';
import { dayTypeColor } from './PayBreakdown';
import { Text } from './Text';

/**
 * The timesheet as a table: one row per worked day with in/out, breaks and
 * every pay category, and a totals row. Scrolls sideways on phones.
 */
export function TimesheetTable({ sheet, i18n, timeZone }: { sheet: TimesheetView; i18n: I18n; timeZone: string }) {
  const t = useTheme();
  const fields = useMemo(() => timesheetDayFields(i18n), [i18n]);
  const list = useListView({ id: 'timesheet-days', fields, defaultSort: { key: 'date', direction: 'asc' }, searchText: (day) => [day.holidayName, i18n.t(`pay.day.${day.dayType}`)] });
  const days = list.apply(sheet.days);
  // Totals follow the rows shown when a filter hides some days.
  const filtered = days.length !== sheet.days.length;
  const d = (m: number) => formatDuration(m);
  const unfiled = (day: TimesheetDay) => day.overtime.unapprovedMinutes - day.pendingOvertimeMinutes;
  const anyFileable = sheet.isMine && days.some((day) => unfiled(day) > 0);
  const sum = (f: (day: TimesheetDay) => number) => days.reduce((n, day) => n + f(day), 0);
  const total = (value: string, strong = true) => <NumCell value={value} strong={strong} />;

  const columns: GridColumn<TimesheetDay>[] = [
    {
      key: 'date', sortKey: 'date',
      title: i18n.t('timesheet.col.date'),
      width: 118,
      render: (day) => (
        <View style={styles.dateCell}>
          <View style={[styles.dot, { backgroundColor: dayTypeColor(day.dayType, t.colors) }]} />
          <Text variant="subhead" weight="600" numberOfLines={1}>
            {i18n.date(day.date, { weekday: 'short', month: 'short', day: 'numeric' })}
          </Text>
        </View>
      ),
      footer: (
        <Text variant="subhead" weight="700">
          {i18n.t('timesheet.col.total')}
        </Text>
      ),
    },
    {
      key: 'type', sortKey: 'dayType',
      title: i18n.t('timesheet.col.dayType'),
      width: 132,
      render: (day) => (
        <Text variant="footnote" color="textSecondary" numberOfLines={2}>
          {day.holidayName ?? i18n.t(`pay.day.${day.dayType}`)}
        </Text>
      ),
    },
    { key: 'in', title: i18n.t('timesheet.col.in'), width: 78, align: 'right', render: (day) => <NumCell value={day.firstIn !== undefined ? i18n.time(day.firstIn, timeZone) : '—'} /> },
    {
      key: 'out',
      title: i18n.t('timesheet.col.out'),
      width: 78,
      align: 'right',
      render: (day) =>
        day.lastOut !== undefined ? (
          <NumCell value={i18n.time(day.lastOut, timeZone)} />
        ) : (
          <Text variant="caption" weight="700" color="success">
            {i18n.t('timesheet.open')}
          </Text>
        ),
    },
    { key: 'break', sortKey: 'break', title: i18n.t('timesheet.col.break'), width: 70, align: 'right', render: (day) => <NumCell value={d(day.breakMinutes)} />, footer: total(d(sum((x) => x.breakMinutes)), false) },
    { key: 'worked', sortKey: 'worked', title: i18n.t('timesheet.worked'), width: 78, align: 'right', render: (day) => <NumCell value={d(day.workedMinutes)} strong />, footer: total(d(filtered ? sum((x) => x.workedMinutes) : sheet.totals.worked)) },
    { key: 'regular', sortKey: 'regular', title: i18n.t('timesheet.col.regular'), width: 78, align: 'right', render: (day) => <NumCell value={d(day.regularMinutes)} />, footer: total(d(filtered ? sum((x) => x.regularMinutes) : sheet.totals.regular), false) },
    {
      key: 'ot', sortKey: 'overtime',
      title: i18n.t('timesheet.col.ot'),
      width: 70,
      align: 'right',
      render: (day) => <NumCell value={d(day.overtimeMinutes)} tone={day.overtime.unapprovedMinutes > 0 ? t.colors.warning : undefined} />,
      footer: total(d(filtered ? sum((x) => x.overtimeMinutes) : sheet.totals.overtime)),
    },
    {
      key: 'otApproved', sortKey: 'otApproved',
      title: i18n.t('timesheet.col.otApproved'),
      width: 92,
      align: 'right',
      render: (day) => <NumCell value={d(day.overtime.approvedMinutes)} tone={t.colors.success} />,
      footer: total(d(filtered ? sum((x) => x.overtime.approvedMinutes) : sheet.totals.approvedOvertime)),
    },
    { key: 'night', sortKey: 'night', title: i18n.t('timesheet.col.night'), width: 70, align: 'right', render: (day) => <NumCell value={d(day.nightMinutes)} />, footer: total(d(filtered ? sum((x) => x.nightMinutes) : sheet.totals.night)) },
    {
      key: 'paid', sortKey: 'paid',
      title: i18n.t('timesheet.col.paid'),
      width: 84,
      align: 'right',
      render: (day) => <NumCell value={d(weightedMinutes(day.lines))} />,
      footer: total(d(filtered ? sum((x) => weightedMinutes(x.lines)) : sheet.totals.weighted)),
    },
    ...(anyFileable
      ? [
          {
            key: 'action',
            title: '',
            width: 96,
            align: 'right' as const,
            render: (day: TimesheetDay) =>
              unfiled(day) > 0 ? (
                <Button
                  title={i18n.t('timesheet.fileOt')}
                  size="small"
                  variant="tonal"
                  onPress={() => router.push({ pathname: '/request-overtime', params: { date: day.date, minutes: String(unfiled(day)) } })}
                />
              ) : null,
          },
        ]
      : []),
  ];

  return (
    <>
      <ListControls state={list} searchPlaceholder={i18n.t('list.search')} resultCount={days.length} />
      <GridTable
      columns={columns}
      rows={days}
      sort={list.sort}
      onSort={list.setSort}
      rowKey={(day) => day.date}
      rowTint={(day) => (day.overtime.unapprovedMinutes > 0 ? t.colors.warningContainer : undefined)}
      rowLabel={(day) =>
        i18n.t('timesheet.rowLabel', {
          date: i18n.date(day.date, { weekday: 'long', month: 'long', day: 'numeric' }),
          worked: d(day.workedMinutes),
          ot: d(day.overtimeMinutes),
          night: d(day.nightMinutes),
        })
      }
      caption={i18n.t('timesheet.daily')}
      emptyLabel={i18n.t('timesheet.noEntries')}
      showFooter={days.length > 0}
    />
    </>
  );
}

const styles = StyleSheet.create({
  dateCell: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  dot: { width: 8, height: 8, borderRadius: 4 },
});
