import { bucketOf, formatClock, formatDuration, localDateKey, sessionTotals, zonedParts, type HomeWidget } from '@nforce/core';
import { router } from 'expo-router';
import { StyleSheet, View } from 'react-native';

import { Checkbox } from '@/components/Controls';
import { Avatar, Meter, Pill } from '@/components/Display';
import { HeroCard } from '@/components/Hero';
import { Icon, type IconName } from '@/components/Icon';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import {
  useApprovals,
  useAttendance,
  useBalances,
  useSession,
  useSetTaskDone,
  useShifts,
  useTasks,
  useTeamPulse,
  queryClient,
  keys,
} from '@/data/queries';
import type { SessionInfo } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n } from '@/i18n';
import { resolveHomeLayout } from '@/state/homeLayout';
import { usePreference } from '@/state/preferences';

/** Relative heights used to balance the two desktop columns. */
const WEIGHT: Readonly<Record<HomeWidget, number>> = { clock: 3, my_work: 3, approvals: 2, next_shift: 2, team_pulse: 2, org_metrics: 2, balances: 2 };

export default function HomeScreen() {
  const t = useTheme();
  const session = useSession();
  const { t: tr } = useI18n();
  const { isDesktop } = useResponsive();
  const order = usePreference('homeOrder');
  const hidden = usePreference('homeHidden');
  if (session.isError) return <Screen><ErrorState onRetry={() => void session.refetch()} /></Screen>;
  if (session.data === undefined) return <Screen><LoadingBlock rows={4} height={120} /></Screen>;
  const s = session.data;
  const widgets = resolveHomeLayout(s.widgets, order, hidden).filter((w) => w.visible).map((w) => w.widget);

  // Desktop: balance widgets across two columns, preserving the user's order.
  const columns: HomeWidget[][] = [[], []];
  const heights = [0, 0];
  for (const w of widgets) {
    const col = (heights[0] ?? 0) <= (heights[1] ?? 0) ? 0 : 1;
    columns[col]?.push(w);
    heights[col] = (heights[col] ?? 0) + WEIGHT[w];
  }

  return (
    <Screen onRefresh={() => queryClient.invalidateQueries({ queryKey: keys.all })}>
      <Greeting session={s} />
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xxl }]}>
          {columns.map((col, i) => (
            <View key={i} style={{ flex: 1, gap: t.space.xxl }}>
              {col.map((w) => (
                <Widget key={w} widget={w} session={s} />
              ))}
            </View>
          ))}
        </View>
      ) : (
        widgets.map((w) => <Widget key={w} widget={w} session={s} />)
      )}
      <View style={styles.footer}>
        <Text variant="footnote" color="textTertiary" align="center">
          {s.organization.name} · {tr(`role.${s.role}`)}
        </Text>
        <Touchable onPress={() => router.navigate('/more/customize')} feedback="none" hitSlop={8} accessibilityRole="link" accessibilityLabel={tr('customize.home')}>
          <View style={[styles.rowCenter, { gap: 6 }]}>
            <Icon name="layout" size={14} color={t.colors.primary} />
            <Text variant="footnote" color="primary" weight="600">
              {tr('customize.home')}
            </Text>
          </View>
        </Touchable>
      </View>
    </Screen>
  );
}

function Widget({ widget, session }: { widget: HomeWidget; session: SessionInfo }) {
  switch (widget) {
    case 'clock':
      return <ClockWidget />;
    case 'approvals':
      return <ApprovalsWidget />;
    case 'next_shift':
      return <NextShiftWidget session={session} />;
    case 'team_pulse':
      return <TeamPulseWidget />;
    case 'org_metrics':
      return <OrgMetricsWidget />;
    case 'my_work':
      return <MyWorkWidget session={session} />;
    case 'balances':
      return <BalancesWidget />;
  }
}

function Greeting({ session }: { session: SessionInfo }) {
  const i18n = useI18n();
  const now = useNow(60_000);
  const hour = zonedParts(now, session.organization.timeZone).hour;
  const key = hour < 12 ? 'home.morning' : hour < 18 ? 'home.afternoon' : 'home.evening';
  const first = session.user.name.split(' ')[0] ?? session.user.name;
  return (
    <View style={styles.greeting}>
      <View style={{ flex: 1 }}>
        <Text variant="subhead" color="textSecondary" style={{ textTransform: 'uppercase', letterSpacing: 0.6 }}>
          {i18n.date(localDateKey(now, session.organization.timeZone), { weekday: 'long', month: 'long', day: 'numeric' })}
        </Text>
        <Text variant="title" accessibilityRole="header">
          {i18n.t(key, { name: first })}
        </Text>
      </View>
      <Avatar initials={session.user.initials} hue={session.user.hue} size={44} />
    </View>
  );
}

function ClockWidget() {
  const t = useTheme();
  const i18n = useI18n();
  const { data } = useAttendance();
  const live = data?.status === 'working' || data?.status === 'on_break';
  const now = useNow(1000, live);
  const worked = data?.today !== undefined ? sessionTotals(data.today, now).workedMs : 0;
  const scheduled = (data?.scheduledTodayMinutes ?? 0) * 60_000;
  const status = data?.status ?? 'off';
  const target = 40 * 60;
  return (
    <HeroCard onPress={() => router.navigate('/clock')} accessibilityLabel={`${i18n.t('home.clockTitle')}: ${formatDuration(Math.floor(worked / 60_000))}, ${i18n.t(`clock.${status}`)}`}>
      <View style={styles.rowBetween}>
        <Text variant="subhead" weight="600" style={styles.onHero}>
          {i18n.t('home.clockTitle')}
        </Text>
        <View style={[styles.heroPill, { borderRadius: 999 }]}>
          <View style={[styles.dot, { backgroundColor: status === 'working' ? '#4ADE80' : status === 'on_break' ? '#FBBF24' : '#CBD5E1' }]} />
          <Text variant="caption" weight="600" style={styles.onHero}>
            {i18n.t(`clock.${status}`)}
          </Text>
        </View>
      </View>
      <Text variant="display" tabular style={[styles.onHero, styles.heroTimer]} maxFontSizeMultiplier={1.2} numberOfLines={1} adjustsFontSizeToFit>
        {formatClock(Math.floor(worked / 1000))}
      </Text>
      <View style={{ gap: t.space.sm }}>
        <View style={styles.heroMeterTrack}>
          <View style={[styles.heroMeterFill, { width: `${scheduled > 0 ? Math.min(100, (worked / scheduled) * 100) : 0}%` }]} />
        </View>
        <View style={styles.rowBetween}>
          <Text variant="footnote" style={styles.onHeroMuted}>
            {scheduled > 0 ? i18n.t('clock.ofScheduled', { time: formatDuration(scheduled / 60_000) }) : i18n.t('clock.noShiftToday')}
          </Text>
          <Text variant="footnote" style={styles.onHeroMuted}>
            {i18n.t('home.weekProgress', { worked: formatDuration(data?.weekWorkedMinutes ?? 0), target: formatDuration(target) })}
          </Text>
        </View>
      </View>
      <View style={[styles.heroCta, { borderRadius: 999 }]}>
        <Icon name="clock" size={16} color="#FFFFFF" weight="semibold" />
        <Text variant="subhead" weight="600" style={styles.onHero}>
          {i18n.t('home.openClock')}
        </Text>
      </View>
    </HeroCard>
  );
}

function ApprovalsWidget() {
  const t = useTheme();
  const { t: tr, plural } = useI18n();
  const approvals = useApprovals();
  const data = approvals.data?.filter((a) => a.canDecide);
  const count = data?.length ?? 0;
  return (
    <Card onPress={() => router.navigate('/more/approvals')} accessibilityLabel={tr('home.approvalsTitle')} style={{ gap: t.space.md }}>
      <View style={styles.rowBetween}>
        <View style={[styles.rowCenter, { gap: t.space.sm }]}>
          <View style={[styles.iconBubble, { backgroundColor: t.colors.warningContainer }]}>
            <Icon name="approvals" size={20} color={t.colors.warning} />
          </View>
          <Text variant="headline">{tr('home.approvalsTitle')}</Text>
        </View>
        {count > 0 && <Pill label={String(count)} tone="danger" />}
      </View>
      <Text variant="subhead" color="textSecondary">
        {count > 0 ? plural('home.approvals', count) : tr('home.approvalsNone')}
      </Text>
      {count > 0 && (
        <View style={styles.avatarStack}>
          {data?.slice(0, 5).map((a, i) => (
            <View key={a.id} style={[styles.stacked, { marginLeft: i === 0 ? 0 : -10, borderColor: t.colors.surface }]}>
              <Avatar initials={a.requester.initials} hue={a.requester.hue} size={32} />
            </View>
          ))}
        </View>
      )}
    </Card>
  );
}

function NextShiftWidget({ session }: { session: SessionInfo }) {
  const t = useTheme();
  const i18n = useI18n();
  const tz = session.organization.timeZone;
  const now = useNow(60_000);
  const today = localDateKey(now, tz);
  const { data } = useShifts(today, 7);
  const next = data?.find((s) => Date.parse(s.end) > now.getTime());
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('home.nextShift')} action={{ label: i18n.t('common.seeAll'), onPress: () => router.navigate('/schedule') }} />
      <Card style={{ gap: t.space.md }}>
        {next === undefined ? (
          <Text variant="subhead" color="textSecondary">
            {data === undefined ? ' ' : i18n.t('home.noShift')}
          </Text>
        ) : (
          <>
            <View style={styles.rowBetween}>
              <View style={{ gap: 2, flex: 1 }}>
                <Text variant="caption" color="primary" weight="700" style={{ textTransform: 'uppercase', letterSpacing: 0.6 }}>
                  {next.date === today ? i18n.t('common.today') : i18n.date(next.date, { weekday: 'long', month: 'short', day: 'numeric' })}
                </Text>
                <Text variant="title2" tabular>
                  {i18n.time(next.start, tz)} – {i18n.time(next.end, tz)}
                </Text>
              </View>
              <View style={[styles.iconBubble, { backgroundColor: t.colors.primaryContainer }]}>
                <Icon name="calendarCheck" size={20} color={t.colors.onPrimaryContainer} />
              </View>
            </View>
            <View style={[styles.rowCenter, { gap: 6 }]}>
              <Icon name="location" size={15} color={t.colors.textSecondary} />
              <Text variant="subhead" color="textSecondary" style={{ flex: 1 }} numberOfLines={1}>
                {next.location} · {next.role}
              </Text>
            </View>
            <View style={styles.avatarStack}>
              {next.teammates.map((p, i) => (
                <View key={p.id} style={[styles.stacked, { marginLeft: i === 0 ? 0 : -8, borderColor: t.colors.surface }]}>
                  <Avatar initials={p.initials} hue={p.hue} size={28} />
                </View>
              ))}
            </View>
          </>
        )}
      </Card>
    </View>
  );
}

function TeamPulseWidget() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const { data } = useTeamPulse();
  const cells: { label: string; value: number; color: string; icon: IconName }[] = [
    { label: tr('clock.working'), value: data?.onShift ?? 0, color: t.colors.success, icon: 'play' },
    { label: tr('clock.on_break'), value: data?.onBreak ?? 0, color: t.colors.warning, icon: 'coffee' },
    { label: tr('home.late'), value: data?.late ?? 0, color: t.colors.danger, icon: 'warning' },
    { label: tr('clock.off'), value: data?.off ?? 0, color: t.colors.textSecondary, icon: 'moon' },
  ];
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={tr('home.teamPulse')} />
      <View style={[styles.grid, { gap: t.space.md }]}>
        {cells.map((c) => (
          <Card key={c.label} style={styles.gridCell} accessibilityLabel={`${c.label}: ${c.value}`}>
            <Icon name={c.icon} size={18} color={c.color} />
            <Text variant="title" tabular style={{ marginTop: 6 }}>
              {data === undefined ? '–' : c.value}
            </Text>
            <Text variant="footnote" color="textSecondary" numberOfLines={1}>
              {c.label}
            </Text>
          </Card>
        ))}
      </View>
    </View>
  );
}

function OrgMetricsWidget() {
  const t = useTheme();
  const i18n = useI18n();
  const metrics = [
    { label: i18n.t('home.attendanceRate'), value: 0.964, color: t.colors.success },
    { label: i18n.t('home.coverage'), value: 0.981, color: t.colors.primary },
    { label: i18n.t('home.overtime'), value: 0.031, color: t.colors.warning },
  ];
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('home.orgMetrics')} />
      <Card style={{ gap: t.space.lg }}>
        {metrics.map((m) => (
          <View key={m.label} style={{ gap: t.space.sm }}>
            <View style={styles.rowBetween}>
              <Text variant="subhead">{m.label}</Text>
              <Text variant="headline" tabular>
                {i18n.number(m.value, { style: 'percent', maximumFractionDigits: 1 })}
              </Text>
            </View>
            <Meter value={m.value} color={m.color} />
          </View>
        ))}
      </Card>
    </View>
  );
}

function MyWorkWidget({ session }: { session: SessionInfo }) {
  const t = useTheme();
  const { t: tr } = useI18n();
  const { data } = useTasks();
  const setDone = useSetTaskDone();
  const today = localDateKey(new Date(), session.organization.timeZone);
  const focus = (data ?? []).filter((task) => ['overdue', 'today'].includes(bucketOf(task, today))).slice(0, 4);
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={tr('home.myWork')} action={{ label: tr('common.seeAll'), onPress: () => router.navigate('/work') }} />
      <Card padded={false}>
        {focus.length === 0 ? (
          <View style={[styles.rowCenter, { padding: t.space.lg, gap: t.space.md }]}>
            <Icon name="sparkles" size={20} color={t.colors.primary} />
            <Text variant="subhead" color="textSecondary">
              {data === undefined ? ' ' : tr('home.caughtUp')}
            </Text>
          </View>
        ) : (
          focus.map((task, i) => {
            const overdue = bucketOf(task, today) === 'overdue';
            return (
              <View
                key={task.id}
                style={[
                  styles.taskRow,
                  { paddingHorizontal: t.space.md },
                  i < focus.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
                ]}
              >
                <Checkbox
                  checked={task.status === 'done'}
                  onToggle={() => setDone.mutate({ id: task.id, done: task.status !== 'done' })}
                  label={tr(task.status === 'done' ? 'work.markOpen' : 'work.markDone', { title: task.title })}
                />
                <Text variant="body" style={{ flex: 1 }} numberOfLines={2}>
                  {task.title}
                </Text>
                {overdue && <Pill label={tr('work.bucket.overdue')} tone="danger" />}
                {task.priority === 'urgent' && !overdue && <Pill label={tr('work.priority.urgent')} tone="warning" />}
              </View>
            );
          })
        )}
      </Card>
    </View>
  );
}

function BalancesWidget() {
  const t = useTheme();
  const i18n = useI18n();
  const { data } = useBalances();
  return (
    <View style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('home.balances')} action={{ label: i18n.t('timeoff.new'), onPress: () => router.navigate('/request-time-off') }} />
      <View style={[styles.grid, { gap: t.space.md }]}>
        {(data ?? []).map((b) => {
          const color = `hsl(${b.hue}, 70%, ${t.scheme === 'dark' ? 65 : 48}%)`;
          return (
            <Card key={b.leaveTypeId} style={[styles.gridCell, { gap: t.space.sm }]} onPress={() => router.navigate('/more/timeoff')} accessibilityLabel={`${b.name}: ${b.available}`}>
              <Text variant="footnote" color="textSecondary" numberOfLines={1}>
                {b.name}
              </Text>
              <Text variant="title2" tabular>
                {i18n.number(b.available)}
                <Text variant="footnote" color="textTertiary">{` / ${i18n.number(b.entitled)}`}</Text>
              </Text>
              <Meter value={b.available / b.entitled} color={color} />
            </Card>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  greeting: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  rowCenter: { flexDirection: 'row', alignItems: 'center' },
  onHero: { color: '#FFFFFF' },
  onHeroMuted: { color: 'rgba(255,255,255,0.8)' },
  heroTimer: { fontSize: 48, lineHeight: 56, fontWeight: '700' },
  heroPill: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 10, paddingVertical: 4, backgroundColor: 'rgba(255,255,255,0.18)' },
  heroMeterTrack: { height: 6, borderRadius: 3, backgroundColor: 'rgba(255,255,255,0.25)', overflow: 'hidden' },
  heroMeterFill: { height: 6, borderRadius: 3, backgroundColor: '#FFFFFF' },
  heroCta: { flexDirection: 'row', alignItems: 'center', alignSelf: 'flex-start', gap: 6, paddingHorizontal: 14, paddingVertical: 8, backgroundColor: 'rgba(255,255,255,0.2)' },
  dot: { width: 8, height: 8, borderRadius: 4 },
  iconBubble: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
  avatarStack: { flexDirection: 'row' },
  stacked: { borderWidth: 2, borderRadius: 999 },
  grid: { flexDirection: 'row', flexWrap: 'wrap' },
  gridCell: { flexGrow: 1, flexBasis: '40%', minWidth: 140 },
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  footer: { alignItems: 'center', gap: 8 },
  taskRow: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 56, paddingVertical: 6 },
});
