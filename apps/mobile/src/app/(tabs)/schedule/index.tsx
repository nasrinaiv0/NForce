import { addDays, formatDuration, isoWeekday, localDateKey, type DateKey } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Avatar } from '@/components/Display';
import { HeroCard } from '@/components/Hero';
import { Icon } from '@/components/Icon';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { useSession, useShifts } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const DAYS = 14;

export default function ScheduleScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const session = useSession();
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const today = localDateKey(new Date(), tz);
  const start = addDays(today, 1 - isoWeekday(today));
  const shifts = useShifts(start, DAYS);
  const [selected, setSelected] = useState<DateKey>(today);

  const days = useMemo(() => Array.from({ length: DAYS }, (_, i) => addDays(start, i)), [start]);
  const byDate = useMemo(() => new Map((shifts.data ?? []).map((s) => [s.date, s])), [shifts.data]);
  const shift = byDate.get(selected);
  const weekShifts = (shifts.data ?? []).filter((s) => s.date >= start && s.date < addDays(start, 7));
  const weekMinutes = weekShifts.reduce((m, s) => m + (Date.parse(s.end) - Date.parse(s.start)) / 60_000 - 60, 0);

  return (
    <Screen onRefresh={() => shifts.refetch()}>
      <FlatList
        horizontal
        data={days}
        keyExtractor={(d) => d}
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={{ gap: t.space.sm, paddingHorizontal: t.space.lg }}
        style={{ marginHorizontal: -t.space.lg, flexGrow: 0 }}
        initialNumToRender={DAYS}
        accessibilityRole="tablist"
        renderItem={({ item }) => (
          <DayPill
            date={item}
            selected={item === selected}
            isToday={item === today}
            hasShift={byDate.has(item)}
            onPress={() => setSelected(item)}
            weekday={i18n.date(item, { weekday: 'narrow' })}
            label={i18n.date(item, { weekday: 'long', month: 'long', day: 'numeric' })}
          />
        )}
      />

      <Text variant="subhead" color="textSecondary">
        {i18n.t('schedule.weekTotal', { count: weekShifts.length, hours: formatDuration(weekMinutes) })}
      </Text>

      {shifts.isError ? (
        <ErrorState onRetry={() => void shifts.refetch()} />
      ) : shifts.data === undefined ? (
        <LoadingBlock rows={2} height={140} />
      ) : shift === undefined ? (
        <EmptyState
          icon="moon"
          title={i18n.date(selected, { weekday: 'long', month: 'long', day: 'numeric' })}
          body={i18n.t('schedule.noShift')}
        />
      ) : (
        <>
          <HeroCard>
            <Text variant="footnote" weight="700" style={styles.heroLabel}>
              {selected === today ? i18n.t('common.today') : i18n.date(selected, { weekday: 'long', month: 'long', day: 'numeric' })}
            </Text>
            <Text variant="title" tabular style={styles.onHero}>
              {i18n.time(shift.start, tz)} – {i18n.time(shift.end, tz)}
            </Text>
            <Text variant="subhead" style={styles.onHeroMuted}>
              {i18n.plural('schedule.hours', Math.round(((Date.parse(shift.end) - Date.parse(shift.start)) / 3_600_000 - 1) * 10) / 10)} · {shift.role}
            </Text>
            <View style={styles.row}>
              <Icon name="location" size={15} color="#FFFFFF" />
              <Text variant="subhead" style={styles.onHero}>
                {shift.location}
              </Text>
            </View>
          </HeroCard>

          <ListSection title={i18n.t('schedule.teammates')}>
            {shift.teammates.map((p, idx) => (
              <ListRow
                key={p.id}
                title={p.name}
                subtitle={p.title}
                leading={<Avatar initials={p.initials} hue={p.hue} size={36} />}
                last={idx === shift.teammates.length - 1}
              />
            ))}
          </ListSection>
        </>
      )}

      <Button
        title={i18n.t('schedule.requestDayOff')}
        icon="timeoff"
        variant="tonal"
        onPress={() => router.push({ pathname: '/request-time-off', params: { kind: 'day_off', start: selected } })}
      />
    </Screen>
  );
}

function DayPill({
  date,
  weekday,
  label,
  selected,
  isToday,
  hasShift,
  onPress,
}: {
  date: DateKey;
  weekday: string;
  label: string;
  selected: boolean;
  isToday: boolean;
  hasShift: boolean;
  onPress: () => void;
}) {
  const t = useTheme();
  const fg = selected ? t.colors.onPrimary : isToday ? t.colors.primary : t.colors.text;
  return (
    <Touchable
      onPress={onPress}
      haptic="selection"
      accessibilityRole="tab"
      accessibilityState={{ selected }}
      accessibilityLabel={label}
      style={[
        styles.day,
        { borderRadius: t.flavor === 'ios' ? 18 : 16, backgroundColor: selected ? t.colors.primary : t.colors.surface },
      ]}
    >
      <Text variant="caption" weight="600" style={{ color: selected ? t.colors.onPrimary : t.colors.textSecondary }}>
        {weekday}
      </Text>
      <Text variant="headline" tabular style={{ color: fg }}>
        {Number(date.slice(8))}
      </Text>
      <View style={[styles.dayDot, { backgroundColor: hasShift ? (selected ? t.colors.onPrimary : t.colors.primary) : 'transparent' }]} />
    </Touchable>
  );
}

const styles = StyleSheet.create({
  day: { width: 56, paddingVertical: 10, alignItems: 'center', gap: 2 },
  dayDot: { width: 5, height: 5, borderRadius: 3, marginTop: 2 },
  onHero: { color: '#FFFFFF' },
  onHeroMuted: { color: 'rgba(255,255,255,0.82)' },
  heroLabel: { color: 'rgba(255,255,255,0.85)', textTransform: 'uppercase', letterSpacing: 0.6 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 6 },
});
