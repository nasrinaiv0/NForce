import { allowedActions, formatClock, formatDuration, sessionTotals, type AttendanceEventType } from '@nforce/core';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Alert, Platform, StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Pill, ProgressRing, Skeleton, type Tone } from '@/components/Display';
import { Icon, type IconName } from '@/components/Icon';
import { ErrorState, Screen } from '@/components/Screen';
import { Card, ListSection, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, newIdempotencyKey, useAttendance, useClock, useSession } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useI18n } from '@/i18n';

const ACTION_ICON: Readonly<Record<AttendanceEventType, IconName>> = {
  clock_in: 'login',
  break_start: 'coffee',
  break_end: 'play',
  clock_out: 'logout',
};

export default function ClockScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { t: tr } = i18n;
  const session = useSession();
  const attendance = useAttendance();
  const clock = useClock();
  const data = attendance.data;
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const live = data?.status === 'working' || data?.status === 'on_break';
  const now = useNow(1000, live);
  const [error, setError] = useState<string | null>(null);

  // One idempotency key per user intent: retrying the same action after a
  // network failure reuses the key, so the server records it exactly once.
  const intent = useRef<{ type: AttendanceEventType; key: string } | null>(null);
  useEffect(() => {
    intent.current = null;
  }, [data?.status]);

  const perform = useCallback(
    (type: AttendanceEventType) => {
      if (intent.current?.type !== type) intent.current = { type, key: newIdempotencyKey() };
      setError(null);
      clock.mutate(
        { type, key: intent.current.key },
        {
          onSuccess: () => {
            haptics.success();
            AccessibilityInfo.announceForAccessibility(tr(`clock.event.${type}`));
          },
          onError: (e) => {
            haptics.error();
            setError(errorMessage(e, tr('common.errorBody')));
          },
        },
      );
    },
    [clock, tr],
  );

  const totals = data?.today !== undefined ? sessionTotals(data.today, now) : { workedMs: 0, breakMs: 0, elapsedMs: 0 };
  const snapshotWorked = data?.today !== undefined ? sessionTotals(data.today, new Date(attendance.dataUpdatedAt)).workedMs : 0;
  const weekMinutes = (data?.weekWorkedMinutes ?? 0) + Math.max(0, Math.floor((totals.workedMs - snapshotWorked) / 60_000));

  const onAction = (type: AttendanceEventType) => {
    if (type !== 'clock_out' || Platform.OS === 'web') return perform(type);
    haptics.warning();
    Alert.alert(tr('clock.confirmOut'), tr('clock.confirmOutBody', { time: formatDuration(Math.floor(totals.workedMs / 60_000)) }), [
      { text: tr('common.cancel'), style: 'cancel' },
      { text: tr('clock.clock_out'), style: 'destructive', onPress: () => perform('clock_out') },
    ]);
  };

  if (attendance.isError && data === undefined) {
    return (
      <Screen>
        <ErrorState onRetry={() => void attendance.refetch()} message={errorMessage(attendance.error, tr('common.errorBody'))} />
      </Screen>
    );
  }

  const status = data?.status ?? 'off';
  const tone: Tone = status === 'working' ? 'success' : status === 'on_break' ? 'warning' : 'neutral';
  const ringGradient: [string, string] =
    status === 'on_break' ? [t.colors.warning, t.colors.warning] : [t.colors.heroStart, t.colors.heroEnd];
  const scheduled = data?.scheduledTodayMinutes ?? 0;
  const workedSeconds = Math.floor(totals.workedMs / 1000);
  const actions = allowedActions(status);

  return (
    <Screen onRefresh={() => attendance.refetch()}>
      <View style={[styles.hero, { gap: t.space.xl }]}>
        {data === undefined ? (
          <Skeleton height={28} width={120} radius={14} />
        ) : (
          <Pill label={tr(`clock.${status}`)} tone={tone} dot />
        )}
        <ProgressRing progress={scheduled > 0 ? totals.workedMs / (scheduled * 60_000) : 0} gradient={ringGradient} size={248} stroke={18}>
          <View style={styles.ringCenter} accessible accessibilityLabel={`${formatDuration(Math.floor(workedSeconds / 60))} ${tr('clock.workedToday')}`}>
            <Text variant="display" tabular style={styles.timer} maxFontSizeMultiplier={1.3} adjustsFontSizeToFit numberOfLines={1}>
              {formatClock(workedSeconds)}
            </Text>
            <Text variant="subhead" color="textSecondary">
              {tr('clock.workedToday')}
            </Text>
            <Text variant="footnote" color="textTertiary">
              {scheduled > 0 ? tr('clock.ofScheduled', { time: formatDuration(scheduled) }) : tr('clock.noShiftToday')}
            </Text>
          </View>
        </ProgressRing>

        <View style={[styles.actions, { gap: t.space.md }]}>
          {actions.map((type) => {
            const primary = type === 'clock_in' || type === 'break_end' || actions.length === 1;
            return (
              <Button
                key={type}
                title={tr(`clock.${type}`)}
                icon={ACTION_ICON[type]}
                variant={type === 'clock_out' ? 'destructive' : primary ? 'filled' : 'tonal'}
                size="large"
                loading={clock.isPending && clock.variables?.type === type}
                disabled={data === undefined || (clock.isPending && clock.variables?.type !== type)}
                onPress={() => onAction(type)}
                style={styles.actionButton}
                testID={`clock-${type}`}
              />
            );
          })}
        </View>
        {error !== null && (
          <Text variant="footnote" color="danger" align="center" accessibilityRole="alert">
            {error}
          </Text>
        )}
      </View>

      <View style={[styles.stats, { gap: t.space.md }]}>
        <Stat label={tr('clock.thisWeek')} value={formatDuration(weekMinutes)} icon="trend" />
        <Stat label={tr('clock.breaks')} value={formatDuration(Math.floor(totals.breakMs / 60_000))} icon="coffee" />
        <Stat
          label={tr('clock.since')}
          value={data?.today !== undefined && live ? i18n.time(data.today.clockIn, tz) : '—'}
          icon="clock"
        />
      </View>

      {data !== undefined && data.exceptions.length > 0 && (
        <Card style={{ backgroundColor: t.colors.warningContainer, gap: t.space.sm }}>
          {data.exceptions.map((ex, idx) => (
            <View key={`${ex.kind}-${idx}`} style={styles.exception}>
              <Icon name="warning" size={18} color={t.colors.warning} />
              <Text variant="subhead" style={{ flex: 1, color: t.colors.warning }}>
                {tr(`clock.exception.${ex.kind}`)}
              </Text>
            </View>
          ))}
        </Card>
      )}

      <View style={{ gap: t.space.md }}>
        <SectionHeader title={tr('clock.activity')} />
        <ListSection footer={tr('clock.serverTime', { zone: tz })}>
          {data === undefined ? (
            <View style={{ padding: t.space.lg, gap: t.space.md }}>
              <Skeleton height={18} />
              <Skeleton height={18} width="70%" />
            </View>
          ) : data.events.length === 0 ? (
            <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
              {tr('clock.noActivity')}
            </Text>
          ) : (
            [...data.events].reverse().map((e, idx, list) => (
              <TimelineRow
                key={e.id}
                icon={ACTION_ICON[e.type]}
                label={tr(`clock.event.${e.type}`)}
                time={i18n.time(e.occurredAt, tz)}
                last={idx === list.length - 1}
              />
            ))
          )}
        </ListSection>
      </View>
    </Screen>
  );
}

function Stat({ label, value, icon }: { label: string; value: string; icon: IconName }) {
  const t = useTheme();
  return (
    <Card style={[styles.stat, { gap: t.space.xs }]}>
      <Icon name={icon} size={18} color={t.colors.primary} />
      <Text variant="headline" tabular numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      <Text variant="caption" color="textSecondary" numberOfLines={1}>
        {label}
      </Text>
    </Card>
  );
}

function TimelineRow({ icon, label, time, last }: { icon: IconName; label: string; time: string; last: boolean }) {
  const t = useTheme();
  return (
    <View style={[styles.timelineRow, { paddingHorizontal: t.space.lg }]} accessible accessibilityLabel={`${label}, ${time}`}>
      <View style={styles.timelineRail}>
        <View style={[styles.timelineDot, { backgroundColor: t.colors.primaryContainer }]}>
          <Icon name={icon} size={14} color={t.colors.onPrimaryContainer} />
        </View>
        {!last && <View style={[styles.timelineLine, { backgroundColor: t.colors.separator }]} />}
      </View>
      <Text variant="body" style={{ flex: 1 }}>
        {label}
      </Text>
      <Text variant="subhead" color="textSecondary" tabular>
        {time}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  hero: { alignItems: 'center', paddingTop: 8 },
  ringCenter: { alignItems: 'center', paddingHorizontal: 24 },
  timer: { fontSize: 44, lineHeight: 52, fontWeight: '600' },
  actions: { flexDirection: 'row', alignSelf: 'stretch' },
  actionButton: { flex: 1 },
  stats: { flexDirection: 'row' },
  stat: { flex: 1, paddingVertical: 14 },
  exception: { flexDirection: 'row', gap: 10, alignItems: 'flex-start' },
  timelineRow: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 52 },
  timelineRail: { alignItems: 'center', alignSelf: 'stretch', justifyContent: 'center', width: 28 },
  timelineDot: { width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  timelineLine: { position: 'absolute', top: 40, bottom: -12, width: 2, borderRadius: 1 },
});
