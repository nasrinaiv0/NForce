import { UserId, addDays, formatDuration, isDateKey, type DateKey, type TimesheetStatus } from '@nforce/core';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { Icon, type IconName } from '@/components/Icon';
import { PayLinesList, RateCard, dayTypeColor } from '@/components/PayBreakdown';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useSession, useTimesheet, useTimesheetAction } from '@/data/queries';
import type { TimesheetDay, TimesheetView } from '@/data/types';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<TimesheetStatus, Tone>> = {
  draft: 'neutral',
  submitted: 'info',
  returned: 'warning',
  approved: 'success',
  locked: 'primary',
};

export default function TimesheetScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const params = useLocalSearchParams<{ user?: string; period?: string }>();
  const userId = typeof params.user === 'string' && params.user.length > 0 ? UserId(params.user) : undefined;
  const [period, setPeriod] = useState<DateKey | undefined>(
    typeof params.period === 'string' && isDateKey(params.period) ? params.period : undefined,
  );
  const session = useSession();
  const sheet = useTimesheet(userId, period);
  const act = useTimesheetAction();
  const tz = session.data?.organization.timeZone ?? 'UTC';

  if (sheet.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void sheet.refetch()} message={errorMessage(sheet.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (sheet.data === undefined || session.data === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={110} />
      </Screen>
    );
  }
  const s = sheet.data;
  const shift = (days: number) => setPeriod(addDays(s.periodStart, days));

  const summary = (
    <View style={{ gap: t.space.lg }}>
      <Card style={{ gap: t.space.lg }}>
        {!s.isMine && (
          <View style={styles.row}>
            <Avatar initials={s.person.initials} hue={s.person.hue} size={40} />
            <View style={{ flex: 1 }}>
              <Text variant="headline">{s.person.name}</Text>
              <Text variant="footnote" color="textSecondary">
                {s.person.title}
              </Text>
            </View>
          </View>
        )}
        <View style={styles.rowBetween}>
          <PeriodNav i18n={i18n} sheet={s} onPrev={() => shift(-7)} onNext={() => shift(7)} />
          <Pill label={i18n.t(`timesheet.status.${s.status}`)} tone={STATUS_TONE[s.status]} dot />
        </View>
        <View style={[styles.kpis, { gap: t.space.md }]}>
          <Kpi icon="clock" label={i18n.t('timesheet.worked')} value={formatDuration(s.totals.worked)} />
          <Kpi
            icon="overtime"
            label={i18n.t('pay.overtime')}
            value={formatDuration(s.totals.overtime)}
            hint={s.totals.overtime > 0 ? i18n.t('timesheet.otApproved', { time: formatDuration(s.totals.approvedOvertime) }) : undefined}
          />
          <Kpi icon="night" label={i18n.t('pay.night')} value={formatDuration(s.totals.night)} />
          <Kpi icon="trend" label={i18n.t('timesheet.paidEquivalent')} value={formatDuration(s.totals.weighted)} hint={i18n.t('timesheet.paidEquivalentHint')} />
        </View>
        {s.actions.map((action) => (
          <Button
            key={action}
            title={i18n.t(`timesheet.action.${action}`)}
            icon="approvals"
            onPress={() =>
              act.mutate({ action, periodStart: s.periodStart }, { onSuccess: () => haptics.success(), onError: () => haptics.error() })
            }
            loading={act.isPending}
          />
        ))}
        {s.status === 'submitted' && s.isMine && (
          <Text variant="footnote" color="textSecondary">
            {i18n.t('timesheet.submittedHint')}
          </Text>
        )}
        {act.isError && (
          <Text variant="footnote" color="danger" accessibilityRole="alert">
            {errorMessage(act.error, i18n.t('common.errorBody'))}
          </Text>
        )}
      </Card>

      <Card style={{ gap: t.space.lg }}>
        <SectionHeader title={i18n.t('timesheet.breakdown')} />
        <PayLinesList lines={s.summary} i18n={i18n} emptyLabel={i18n.t('timesheet.noEntries')} />
      </Card>

      <Card>
        <RateCard policy={session.data.payPolicy} i18n={i18n} />
      </Card>
    </View>
  );

  const daily = (
    <View style={{ gap: t.space.lg }}>
      <ListSection title={i18n.t('timesheet.daily')} footer={i18n.t('timesheet.footer')}>
        {s.days.length === 0 ? (
          <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
            {i18n.t('timesheet.noEntries')}
          </Text>
        ) : (
          s.days.map((d, idx) => <DayRow key={d.date} day={d} last={idx === s.days.length - 1} i18n={i18n} canFile={s.isMine} />)
        )}
      </ListSection>
      {s.history.length > 0 && (
        <ListSection title={i18n.t('timesheet.history')}>
          {s.history.map((h, idx) => (
            <ListRow
              key={`${h.at}-${idx}`}
              title={i18n.t(`timesheet.status.${h.to}`)}
              subtitle={h.reason}
              value={`${i18n.date(h.at.slice(0, 10) as DateKey, { month: 'short', day: 'numeric' })} ${i18n.time(h.at, tz)}`}
              last={idx === s.history.length - 1}
            />
          ))}
        </ListSection>
      )}
    </View>
  );

  return (
    <Screen onRefresh={() => sheet.refetch()}>
      <Stack.Screen options={{ title: s.isMine ? i18n.t('timesheet.title') : s.person.name }} />
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xxl }]}>
          <View style={{ flex: 1 }}>{summary}</View>
          <View style={{ flex: 1.2 }}>{daily}</View>
        </View>
      ) : (
        <>
          {summary}
          {daily}
        </>
      )}
    </Screen>
  );
}

function PeriodNav({ i18n, sheet, onPrev, onNext }: { i18n: I18n; sheet: TimesheetView; onPrev: () => void; onNext: () => void }) {
  const t = useTheme();
  const fmt = { month: 'short', day: 'numeric' } as const;
  const arrow = (dir: 'prev' | 'next', onPress: () => void) => (
    <Touchable
      onPress={onPress}
      haptic="selection"
      feedback="highlight"
      accessibilityLabel={i18n.t(dir === 'prev' ? 'timesheet.prevPeriod' : 'timesheet.nextPeriod')}
      style={[styles.navBtn, { backgroundColor: t.colors.fill }]}
    >
      <View style={dir === 'prev' ? { transform: [{ scaleX: -1 }] } : undefined}>
        <Icon name="chevron" size={14} color={t.colors.primary} weight="semibold" />
      </View>
    </Touchable>
  );
  return (
    <View style={styles.row}>
      {arrow('prev', onPrev)}
      <Text variant="headline" tabular accessibilityRole="header">
        {i18n.date(sheet.periodStart, fmt)} – {i18n.date(sheet.periodEnd, fmt)}
      </Text>
      {arrow('next', onNext)}
    </View>
  );
}

function Kpi({ icon, label, value, hint }: { icon: IconName; label: string; value: string; hint?: string | undefined }) {
  const t = useTheme();
  return (
    <View style={[styles.kpi, { backgroundColor: t.colors.fill, borderRadius: t.shape.control }]} accessible accessibilityLabel={`${label}: ${value}${hint !== undefined ? `, ${hint}` : ''}`}>
      <Icon name={icon} size={16} color={t.colors.primary} />
      <Text variant="title2" tabular numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      <Text variant="caption" color="textSecondary" numberOfLines={1}>
        {label}
      </Text>
      {hint !== undefined && (
        <Text variant="caption" color="textTertiary" numberOfLines={2}>
          {hint}
        </Text>
      )}
    </View>
  );
}

function DayRow({ day, last, i18n, canFile }: { day: TimesheetDay; last: boolean; i18n: I18n; canFile: boolean }) {
  const t = useTheme();
  const unfiled = day.overtime.unapprovedMinutes - day.pendingOvertimeMinutes;
  const tags: { label: string; icon: IconName; color: string }[] = [];
  if (day.holidayName !== undefined) tags.push({ label: day.holidayName, icon: 'holiday', color: dayTypeColor(day.dayType, t.colors) });
  if (day.restDay) tags.push({ label: i18n.t('pay.day.rest_day'), icon: 'restDay', color: t.colors.info });
  if (day.nightMinutes > 0) tags.push({ label: `${i18n.t('pay.nightShort')} ${formatDuration(day.nightMinutes)}`, icon: 'night', color: t.colors.textSecondary });

  return (
    <View
      style={[
        { paddingHorizontal: t.space.lg, paddingVertical: t.space.md, gap: t.space.sm },
        !last && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
      ]}
    >
      <View style={styles.rowBetween}>
        <View style={[styles.row, { flex: 1 }]}>
          <View style={[styles.dayDot, { backgroundColor: dayTypeColor(day.dayType, t.colors) }]} />
          <Text variant="body" weight="600" numberOfLines={1}>
            {i18n.date(day.date, { weekday: 'long', month: 'short', day: 'numeric' })}
          </Text>
        </View>
        <Text variant="body" tabular weight="600">
          {formatDuration(day.workedMinutes)}
        </Text>
      </View>
      {tags.length > 0 && (
        <View style={styles.tags}>
          {tags.map((tag) => (
            <View key={tag.label} style={[styles.tag, { backgroundColor: t.colors.fill }]}>
              <Icon name={tag.icon} size={12} color={tag.color} />
              <Text variant="caption" color="textSecondary">
                {tag.label}
              </Text>
            </View>
          ))}
        </View>
      )}
      <Text variant="footnote" color="textSecondary">
        {day.lines.map((l) => `${l.code} ${formatDuration(l.minutes)}`).join('  ·  ')} · {i18n.t('clock.breaks')} {formatDuration(day.breakMinutes)}
      </Text>
      {day.excessMinutes > 0 && (
        <Text variant="caption" color="textTertiary">
          {i18n.t('timesheet.excess', { time: formatDuration(day.excessMinutes) })}
        </Text>
      )}
      {day.overtimeMinutes > 0 && (
        <View style={[styles.rowBetween, styles.ot, { backgroundColor: day.overtime.unapprovedMinutes > 0 ? t.colors.warningContainer : t.colors.successContainer, borderRadius: t.shape.control }]}>
          <View style={[styles.row, { flex: 1 }]}>
            <Icon name="overtime" size={15} color={day.overtime.unapprovedMinutes > 0 ? t.colors.warning : t.colors.success} />
            <Text variant="footnote" style={{ flex: 1, color: day.overtime.unapprovedMinutes > 0 ? t.colors.warning : t.colors.success }}>
              {i18n.t('timesheet.otLine', {
                worked: formatDuration(day.overtimeMinutes),
                approved: formatDuration(day.overtime.approvedMinutes),
                pending: formatDuration(day.pendingOvertimeMinutes),
              })}
            </Text>
          </View>
          {canFile && unfiled > 0 && (
            <Button
              title={i18n.t('timesheet.fileOt')}
              size="small"
              variant="tonal"
              onPress={() => router.push({ pathname: '/request-overtime', params: { date: day.date, minutes: String(unfiled) } })}
            />
          )}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' },
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  kpis: { flexDirection: 'row', flexWrap: 'wrap' },
  kpi: { flexGrow: 1, flexBasis: '42%', padding: 12, gap: 2 },
  navBtn: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
  dayDot: { width: 8, height: 8, borderRadius: 4 },
  tags: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  tag: { flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 8, paddingVertical: 3, borderRadius: 999 },
  ot: { padding: 10, gap: 8 },
});
