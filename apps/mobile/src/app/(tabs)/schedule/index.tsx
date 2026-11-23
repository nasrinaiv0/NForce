import { addDays, formatDuration, isoWeekday, localDateKey, type DateKey } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo, useState, type ReactNode } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { SegmentedControl } from '@/components/Controls';
import { Avatar } from '@/components/Display';
import { GridTable, NumCell, type GridColumn } from '@/components/GridTable';
import { HeroCard } from '@/components/Hero';
import { Icon } from '@/components/Icon';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { useSession, useShifts, useTeamSchedule } from '@/data/queries';
import type { RosterCell, RosterRow, Shift } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

type ViewMode = 'day' | 'week' | 'month';
type Scope = 'mine' | 'team';
const DAY_STRIP = 14;

const mondayOf = (d: DateKey) => addDays(d, 1 - isoWeekday(d));
const firstOfMonth = (d: DateKey) => `${d.slice(0, 8)}01` as DateKey;
const addMonths = (d: DateKey, n: number): DateKey => {
  const [y, m] = [Number(d.slice(0, 4)), Number(d.slice(5, 7)) - 1 + n];
  const yy = y + Math.floor(m / 12);
  const mm = ((m % 12) + 12) % 12;
  return `${yy}-${String(mm + 1).padStart(2, '0')}-01` as DateKey;
};

export default function ScheduleScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const session = useSession();
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const today = localDateKey(new Date(), tz);
  const canSeeTeam = session.data?.capabilities.teamSchedule === true;

  const [mode, setMode] = useState<ViewMode>('week');
  const [scope, setScope] = useState<Scope>('mine');
  const [selected, setSelected] = useState<DateKey>(today);
  const [weekStart, setWeekStart] = useState<DateKey>(mondayOf(today));
  const [month, setMonth] = useState<DateKey>(firstOfMonth(today));

  const openDay = (d: DateKey) => {
    setSelected(d);
    setMode('day');
  };

  return (
    <Screen>
      <View style={[styles.controls, { gap: t.space.md }]}>
        <View style={{ flexGrow: 1, minWidth: 240, maxWidth: 420 }}>
          <SegmentedControl
            segments={[
              { value: 'day', label: i18n.t('schedule.view.day') },
              { value: 'week', label: i18n.t('schedule.view.week') },
              { value: 'month', label: i18n.t('schedule.view.month') },
            ]}
            value={mode}
            onChange={setMode}
          />
        </View>
        {mode === 'week' && canSeeTeam && (
          <View style={{ flexGrow: 1, minWidth: 240, maxWidth: 360 }}>
            <SegmentedControl
              segments={[
                { value: 'mine', label: i18n.t('schedule.mine') },
                { value: 'team', label: i18n.t('schedule.team') },
              ]}
              value={scope}
              onChange={setScope}
            />
          </View>
        )}
      </View>

      {mode === 'day' && <DayView i18n={i18n} tz={tz} today={today} selected={selected} onSelect={setSelected} />}
      {mode === 'week' && (
        <WeekView
          i18n={i18n}
          tz={tz}
          today={today}
          start={weekStart}
          scope={canSeeTeam ? scope : 'mine'}
          onShift={(days) => setWeekStart(addDays(weekStart, days))}
          onThisWeek={() => setWeekStart(mondayOf(today))}
          onOpenDay={openDay}
        />
      )}
      {mode === 'month' && (
        <MonthView i18n={i18n} tz={tz} today={today} month={month} onShift={(n) => setMonth(addMonths(month, n))} onOpenDay={openDay} />
      )}
    </Screen>
  );
}

// ------------------------------------------------------------------ helpers

function shiftLabel(cell: RosterCell, i18n: I18n, tz: string): string {
  switch (cell.kind) {
    case 'shift':
      return `${i18n.time(cell.start, tz)}–${i18n.time(cell.end, tz)}`;
    case 'off':
      return i18n.t('schedule.off');
    case 'leave':
      return i18n.t('schedule.leave');
    case 'holiday':
      return cell.name;
  }
}

function CellChip({ cell, i18n, tz, compact = false, stacked = false }: { cell: RosterCell; i18n: I18n; tz: string; compact?: boolean; stacked?: boolean }) {
  const t = useTheme();
  if (cell.kind === 'shift' && stacked) {
    return (
      <View>
        <View style={styles.shiftCell}>
          {cell.night && <Icon name="night" size={12} color={t.colors.info} />}
          <Text variant="footnote" weight="700" tabular numberOfLines={1}>
            {i18n.time(cell.start, tz)}
          </Text>
        </View>
        <Text variant="caption" color="textSecondary" tabular numberOfLines={1}>
          – {i18n.time(cell.end, tz)}
        </Text>
      </View>
    );
  }
  if (cell.kind === 'shift') {
    return (
      <View style={styles.shiftCell}>
        {cell.night && <Icon name="night" size={12} color={t.colors.info} />}
        <Text variant={compact ? 'caption' : 'subhead'} weight="600" tabular numberOfLines={1}>
          {compact ? i18n.time(cell.start, tz) : shiftLabel(cell, i18n, tz)}
        </Text>
      </View>
    );
  }
  const bg = cell.kind === 'leave' ? t.colors.infoContainer : cell.kind === 'holiday' ? t.colors.warningContainer : 'transparent';
  const fg = cell.kind === 'leave' ? t.colors.info : cell.kind === 'holiday' ? t.colors.warning : t.colors.textTertiary;
  return (
    <View style={[styles.tag, { backgroundColor: bg }]}>
      <Text variant="caption" weight="600" style={{ color: fg }} numberOfLines={1}>
        {shiftLabel(cell, i18n, tz)}
      </Text>
    </View>
  );
}

function RangeNav({ label, prevLabel, nextLabel, onPrev, onNext, extra }: { label: string; prevLabel: string; nextLabel: string; onPrev: () => void; onNext: () => void; extra?: ReactNode }) {
  const t = useTheme();
  const arrow = (dir: 'prev' | 'next') => (
    <Touchable
      onPress={dir === 'prev' ? onPrev : onNext}
      haptic="selection"
      feedback="highlight"
      accessibilityLabel={dir === 'prev' ? prevLabel : nextLabel}
      style={[styles.navBtn, { backgroundColor: t.colors.fill }]}
    >
      <View style={dir === 'prev' ? { transform: [{ scaleX: -1 }] } : undefined}>
        <Icon name="chevron" size={14} color={t.colors.primary} weight="semibold" />
      </View>
    </Touchable>
  );
  return (
    <View style={[styles.rowBetween, { gap: t.space.md }]}>
      <View style={styles.row}>
        {arrow('prev')}
        <Text variant="headline" tabular accessibilityRole="header">
          {label}
        </Text>
        {arrow('next')}
      </View>
      {extra}
    </View>
  );
}

// ------------------------------------------------------------------ week

function WeekView({
  i18n,
  tz,
  today,
  start,
  scope,
  onShift,
  onThisWeek,
  onOpenDay,
}: {
  i18n: I18n;
  tz: string;
  today: DateKey;
  start: DateKey;
  scope: Scope;
  onShift: (days: number) => void;
  onThisWeek: () => void;
  onOpenDay: (d: DateKey) => void;
}) {
  const t = useTheme();
  const roster = useTeamSchedule(start, 7);
  const shifts = useShifts(start, 7);
  const end = addDays(start, 6);
  const fmt = { month: 'short', day: 'numeric' } as const;
  const mine = roster.data?.find((r) => r.isMe);
  const isThisWeek = start === mondayOf(today);

  const nav = (
    <RangeNav
      label={`${i18n.date(start, fmt)} – ${i18n.date(end, fmt)}`}
      prevLabel={i18n.t('schedule.prevWeek')}
      nextLabel={i18n.t('schedule.nextWeek')}
      onPrev={() => onShift(-7)}
      onNext={() => onShift(7)}
      extra={!isThisWeek ? <Button title={i18n.t('schedule.thisWeek')} size="small" variant="tonal" onPress={onThisWeek} /> : undefined}
    />
  );

  if (roster.isError) return <ErrorState onRetry={() => void roster.refetch()} />;
  if (roster.data === undefined || mine === undefined) {
    return (
      <>
        {nav}
        <LoadingBlock rows={4} height={52} />
      </>
    );
  }

  if (scope === 'team') {
    const others = roster.data;
    const dayCols: GridColumn<RosterRow>[] = mine.days.map(({ date }) => ({
      key: date,
      title: `${i18n.date(date, { weekday: 'short' })} ${Number(date.slice(8))}`,
      width: 96,
      render: (row: RosterRow) => {
        const cell = row.days.find((d) => d.date === date)?.cell ?? { kind: 'off' as const };
        return (
          <View accessible accessibilityLabel={i18n.t('schedule.cellLabel', { name: row.person.name, date: i18n.date(date, { weekday: 'long', month: 'long', day: 'numeric' }), value: shiftLabel(cell, i18n, tz) })}>
            <CellChip cell={cell} i18n={i18n} tz={tz} stacked />
          </View>
        );
      },
    }));
    const columns: GridColumn<RosterRow>[] = [
      {
        key: 'person',
        title: i18n.t('schedule.col.person'),
        width: 190,
        render: (row) => (
          <View style={styles.row}>
            <Avatar initials={row.person.initials} hue={row.person.hue} size={28} />
            <View style={{ flex: 1 }}>
              <Text variant="subhead" weight={row.isMe ? '700' : '600'} numberOfLines={1}>
                {row.person.name}
              </Text>
              <Text variant="caption" color="textSecondary" numberOfLines={1}>
                {row.teamName ?? i18n.t(`role.${row.role}`)}
              </Text>
            </View>
          </View>
        ),
      },
      ...dayCols,
      { key: 'hours', title: i18n.t('schedule.col.hours'), width: 76, align: 'right', render: (row) => <NumCell value={formatDuration(row.minutes)} strong /> },
    ];
    return (
      <>
        {nav}
        {others.length <= 1 ? (
          <EmptyState icon="team" title={i18n.t('schedule.team')} body={i18n.t('schedule.teamEmpty')} />
        ) : (
          <GridTable columns={columns} rows={others} rowKey={(r) => r.person.id} caption={i18n.t('schedule.team')} rowTint={(r) => (r.isMe ? t.colors.primaryContainer : undefined)} />
        )}
      </>
    );
  }

  const byDate = new Map<string, Shift>((shifts.data ?? []).map((s) => [s.date, s]));
  type DayRowData = { date: DateKey; cell: RosterCell; shift: Shift | undefined };
  const rows: DayRowData[] = mine.days.map((d) => ({ date: d.date, cell: d.cell, shift: byDate.get(d.date) }));
  const count = rows.filter((r) => r.cell.kind === 'shift').length;
  const columns: GridColumn<DayRowData>[] = [
    {
      key: 'date',
      title: i18n.t('schedule.col.date'),
      width: 128,
      render: (r) => (
        <View>
          <Text variant="subhead" weight="600" numberOfLines={1}>
            {i18n.date(r.date, { weekday: 'short', month: 'short', day: 'numeric' })}
          </Text>
          {r.date === today && (
            <Text variant="caption" weight="700" color="primary">
              {i18n.t('common.today')}
            </Text>
          )}
        </View>
      ),
    },
    { key: 'shift', title: i18n.t('schedule.col.shift'), width: 150, render: (r) => <CellChip cell={r.cell} i18n={i18n} tz={tz} /> },
    { key: 'hours', title: i18n.t('schedule.col.hours'), width: 76, align: 'right', render: (r) => <NumCell value={r.cell.kind === 'shift' ? formatDuration(r.cell.minutes) : '—'} /> },
    {
      key: 'role',
      title: i18n.t('schedule.col.role'),
      width: 170,
      render: (r) => (
        <Text variant="footnote" color="textSecondary" numberOfLines={1}>
          {r.shift?.role ?? '—'}
        </Text>
      ),
    },
    {
      key: 'location',
      title: i18n.t('schedule.col.location'),
      width: 170,
      render: (r) => (
        <Text variant="footnote" color="textSecondary" numberOfLines={1}>
          {r.shift?.location ?? '—'}
        </Text>
      ),
    },
    {
      key: 'notes',
      title: i18n.t('schedule.col.notes'),
      width: 150,
      render: (r) => (
        <Text variant="footnote" color="textSecondary" numberOfLines={2}>
          {[r.shift?.holiday?.name, r.cell.kind === 'shift' && r.cell.night ? i18n.t('schedule.night') : undefined].filter(Boolean).join(' · ') || '—'}
        </Text>
      ),
    },
  ];
  return (
    <>
      {nav}
      <Text variant="subhead" color="textSecondary">
        {i18n.t('schedule.weekTotal', { count, hours: formatDuration(mine.minutes) })}
      </Text>
      <GridTable
        columns={columns}
        rows={rows}
        rowKey={(r) => r.date}
        onRowPress={(r) => onOpenDay(r.date)}
        rowLabel={(r) => `${i18n.date(r.date, { weekday: 'long', month: 'long', day: 'numeric' })}: ${shiftLabel(r.cell, i18n, tz)}`}
        rowTint={(r) => (r.date === today ? t.colors.primaryContainer : undefined)}
        caption={i18n.t('schedule.mine')}
      />
      <Button title={i18n.t('schedule.requestDayOff')} icon="timeoff" variant="tonal" onPress={() => router.push({ pathname: '/request-time-off', params: { kind: 'day_off', start: today } })} />
    </>
  );
}

// ------------------------------------------------------------------ month

function MonthView({ i18n, tz, today, month, onShift, onOpenDay }: { i18n: I18n; tz: string; today: DateKey; month: DateKey; onShift: (n: number) => void; onOpenDay: (d: DateKey) => void }) {
  const t = useTheme();
  const { isDesktop } = useResponsive();
  const gridStart = mondayOf(month);
  const roster = useTeamSchedule(gridStart, 42);
  const mine = roster.data?.find((r) => r.isMe);
  const cells = useMemo(() => Array.from({ length: 42 }, (_, i) => addDays(gridStart, i)), [gridStart]);
  const byDate = new Map((mine?.days ?? []).map((d) => [d.date as string, d.cell]));
  const inMonth = (d: DateKey) => d.slice(0, 7) === month.slice(0, 7);
  const monthCells = (mine?.days ?? []).filter((d) => inMonth(d.date));
  const monthMinutes = monthCells.reduce((n, d) => n + (d.cell.kind === 'shift' ? d.cell.minutes : 0), 0);
  const monthCount = monthCells.filter((d) => d.cell.kind === 'shift').length;

  return (
    <>
      <RangeNav
        label={i18n.date(month, { month: 'long', year: 'numeric' })}
        prevLabel={i18n.t('schedule.prevMonth')}
        nextLabel={i18n.t('schedule.nextMonth')}
        onPrev={() => onShift(-1)}
        onNext={() => onShift(1)}
      />
      {roster.isError ? (
        <ErrorState onRetry={() => void roster.refetch()} />
      ) : mine === undefined ? (
        <LoadingBlock rows={5} height={64} />
      ) : (
        <>
          <Text variant="subhead" color="textSecondary">
            {i18n.t('schedule.monthTotal', { count: monthCount, hours: formatDuration(monthMinutes) })}
          </Text>
          <View style={{ backgroundColor: t.colors.surface, borderRadius: t.shape.card, overflow: 'hidden' }} accessibilityRole="grid">
            <View style={[styles.week, { backgroundColor: t.colors.fill }]}>
              {cells.slice(0, 7).map((d) => (
                <View key={d} style={styles.weekdayHead}>
                  <Text variant="caption" weight="700" color="textSecondary">
                    {i18n.date(d, { weekday: isDesktop ? 'short' : 'narrow' })}
                  </Text>
                </View>
              ))}
            </View>
            {Array.from({ length: 6 }, (_, w) => (
              <View key={w} style={[styles.week, { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: t.colors.separator }]}>
                {cells.slice(w * 7, w * 7 + 7).map((d) => {
                  const cell = byDate.get(d) ?? ({ kind: 'off' } as const);
                  const isToday = d === today;
                  const dim = !inMonth(d);
                  return (
                    <Touchable
                      key={d}
                      onPress={() => onOpenDay(d)}
                      feedback="highlight"
                      accessibilityRole="button"
                      accessibilityLabel={`${i18n.date(d, { weekday: 'long', month: 'long', day: 'numeric' })}: ${shiftLabel(cell, i18n, tz)}`}
                      style={[styles.dayCell, { minHeight: isDesktop ? 84 : 58, opacity: dim ? 0.45 : 1 }]}
                    >
                      <View style={[styles.dayNum, isToday && { backgroundColor: t.colors.primary }]}>
                        <Text variant="footnote" weight="700" tabular style={{ color: isToday ? t.colors.onPrimary : t.colors.text }}>
                          {Number(d.slice(8))}
                        </Text>
                      </View>
                      {cell.kind === 'off' ? null : isDesktop ? (
                        <CellChip cell={cell} i18n={i18n} tz={tz} />
                      ) : cell.kind === 'shift' ? (
                        <View style={[styles.bar, { backgroundColor: cell.night ? t.colors.info : t.colors.primary }]} />
                      ) : (
                        <View style={[styles.bar, { backgroundColor: cell.kind === 'leave' ? t.colors.info : t.colors.warning, opacity: 0.5 }]} />
                      )}
                    </Touchable>
                  );
                })}
              </View>
            ))}
          </View>
        </>
      )}
    </>
  );
}

// ------------------------------------------------------------------ day

function DayView({ i18n, tz, today, selected, onSelect }: { i18n: I18n; tz: string; today: DateKey; selected: DateKey; onSelect: (d: DateKey) => void }) {
  const t = useTheme();
  const start = mondayOf(selected < today ? selected : today);
  const shifts = useShifts(start, DAY_STRIP);
  const days = useMemo(() => Array.from({ length: DAY_STRIP }, (_, i) => addDays(start, i)), [start]);
  const byDate = useMemo(() => new Map((shifts.data ?? []).map((s) => [s.date, s])), [shifts.data]);
  const shift = byDate.get(selected);

  return (
    <>
      <FlatList
        horizontal
        data={days}
        keyExtractor={(d) => d}
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={{ gap: t.space.sm, paddingHorizontal: t.space.lg }}
        style={{ marginHorizontal: -t.space.lg, flexGrow: 0 }}
        initialNumToRender={DAY_STRIP}
        accessibilityRole="tablist"
        renderItem={({ item }) => (
          <DayPill
            date={item}
            selected={item === selected}
            isToday={item === today}
            hasShift={byDate.has(item)}
            onPress={() => onSelect(item)}
            weekday={i18n.date(item, { weekday: 'narrow' })}
            label={i18n.date(item, { weekday: 'long', month: 'long', day: 'numeric' })}
          />
        )}
      />

      {shifts.isError ? (
        <ErrorState onRetry={() => void shifts.refetch()} />
      ) : shifts.data === undefined ? (
        <LoadingBlock rows={2} height={140} />
      ) : shift === undefined ? (
        <EmptyState icon="moon" title={i18n.date(selected, { weekday: 'long', month: 'long', day: 'numeric' })} body={i18n.t('schedule.noShift')} />
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
              <ListRow key={p.id} title={p.name} subtitle={p.title} leading={<Avatar initials={p.initials} hue={p.hue} size={36} />} last={idx === shift.teammates.length - 1} />
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
    </>
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
      style={[styles.day, { borderRadius: t.flavor === 'ios' ? 18 : 16, backgroundColor: selected ? t.colors.primary : t.colors.surface }]}
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
  controls: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap' },
  navBtn: { width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
  shiftCell: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  tag: { paddingHorizontal: 8, paddingVertical: 3, borderRadius: 999, alignSelf: 'flex-start' },
  week: { flexDirection: 'row' },
  weekdayHead: { flex: 1, paddingVertical: 8, alignItems: 'center' },
  dayCell: { flex: 1, padding: 6, gap: 4, alignItems: 'flex-start' },
  dayNum: { minWidth: 24, height: 24, borderRadius: 12, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 },
  bar: { height: 4, borderRadius: 2, alignSelf: 'stretch' },
  day: { width: 56, paddingVertical: 10, alignItems: 'center', gap: 2 },
  dayDot: { width: 5, height: 5, borderRadius: 3, marginTop: 2 },
  onHero: { color: '#FFFFFF' },
  onHeroMuted: { color: 'rgba(255,255,255,0.82)' },
  heroLabel: { color: 'rgba(255,255,255,0.85)', textTransform: 'uppercase', letterSpacing: 0.6 },
});
