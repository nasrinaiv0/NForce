import {
  allowedActions,
  bucketOf,
  compareTasks,
  formatClock,
  formatDuration,
  localDateKey,
  sessionTotals,
  zonedParts,
  type HomeWidget,
} from '@nforce/core';
import { router, type Href } from 'expo-router';
import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { useApprovals, useAttendance, useBalances, useExecutiveReport, useSetTaskDone, useShifts, useTasks, useTeamPulse } from '@/data/queries';
import type { SessionInfo } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useI18n } from '@/i18n';
import { Button } from './Button';
import { Checkbox } from './Controls';
import { Avatar, Meter, Pill, type Tone } from './Display';
import { Icon, type IconName } from './Icon';
import { describeRequest } from './requestText';
import { Text } from './Text';
import { Touchable } from './Touchable';

/**
 * Desktop Home: one centered column, compact and scannable.
 * Header → summary strip → panels in the user's chosen order.
 */
export function DesktopHome({ session, widgets }: { session: SessionInfo; widgets: readonly HomeWidget[] }) {
  const t = useTheme();
  const i18n = useI18n();
  const tz = session.organization.timeZone;
  const now = useNow(60_000);
  const hour = zonedParts(now, tz).hour;
  const greeting = hour < 12 ? 'home.morning' : hour < 18 ? 'home.afternoon' : 'home.evening';
  const attendance = useAttendance();
  const next = allowedActions(attendance.data?.status ?? 'off');
  const primary = next.includes('clock_in') ? 'clock_in' : next.includes('clock_out') ? 'clock_out' : undefined;

  return (
    <View style={{ gap: t.space.lg }}>
      <View style={styles.header}>
        <View style={{ flex: 1 }}>
          <Text variant="caption" color="textSecondary" weight="600" style={styles.eyebrow}>
            {i18n.date(localDateKey(now, tz), { weekday: 'long', month: 'long', day: 'numeric' })} · {session.organization.name}
          </Text>
          <Text variant="title2" accessibilityRole="header">
            {i18n.t(greeting, { name: session.user.name.split(' ')[0] ?? session.user.name })}
          </Text>
        </View>
        <View style={styles.actions}>
          {primary !== undefined && <Button title={i18n.t(`clock.${primary}`)} icon={primary === 'clock_in' ? 'login' : 'logout'} size="small" variant={primary === 'clock_in' ? 'filled' : 'tonal'} onPress={() => router.navigate('/clock')} />}
          <Button title={i18n.t('timeoff.new')} icon="timeoff" size="small" variant="tonal" onPress={() => router.push('/request-time-off')} />
          <Button title={i18n.t('work.new')} icon="add" size="small" variant="tonal" onPress={() => router.push('/new-task')} />
        </View>
      </View>

      <SummaryStrip session={session} widgets={widgets} />

      {widgets.map((w) => (
        <PanelFor key={w} widget={w} session={session} />
      ))}

      <View style={styles.footer}>
        <Text variant="caption" color="textTertiary">
          {i18n.t(`role.${session.role}`)}
          {session.teamName !== undefined ? ` · ${session.teamName}` : ''}
          {session.manager !== undefined ? ` · ${i18n.t('admin.reportsTo', { name: session.manager.name })}` : ''}
        </Text>
        <Touchable onPress={() => router.navigate('/more/customize')} feedback="none" hitSlop={8} accessibilityRole="link" accessibilityLabel={i18n.t('customize.home')}>
          <View style={styles.inline}>
            <Icon name="layout" size={13} color={t.colors.primary} />
            <Text variant="caption" color="primary" weight="600">
              {i18n.t('customize.home')}
            </Text>
          </View>
        </Touchable>
      </View>
    </View>
  );
}

function SummaryStrip({ session, widgets }: { session: SessionInfo; widgets: readonly HomeWidget[] }) {
  const t = useTheme();
  const i18n = useI18n();
  const tz = session.organization.timeZone;
  const attendance = useAttendance();
  const status = attendance.data?.status ?? 'off';
  const live = status === 'working' || status === 'on_break';
  const now = useNow(1000, live);
  const worked = attendance.data?.today !== undefined ? sessionTotals(attendance.data.today, now).workedMs : 0;
  const today = localDateKey(now, tz);
  const shifts = useShifts(today, 7);
  const nextShift = shifts.data?.find((s) => Date.parse(s.end) > now.getTime());
  const canApprove = session.modules.includes('approvals');
  const approvals = useApprovals(canApprove);
  const pending = (approvals.data ?? []).filter((a) => a.canDecide).length;
  const balances = useBalances();
  const vacation = balances.data?.find((b) => b.leaveTypeId === 'vacation');
  const statusTone = status === 'working' ? t.colors.success : status === 'on_break' ? t.colors.warning : t.colors.textTertiary;
  const week = attendance.data?.weekWorkedMinutes ?? 0;

  const cells: { key: string; label: string; value: ReactNode; sub?: ReactNode; href: Href; a11y: string }[] = [
    {
      key: 'status',
      label: i18n.t('home.clockTitle'),
      value: (
        <Text variant="headline" tabular>
          {formatClock(Math.floor(worked / 1000))}
        </Text>
      ),
      sub: (
        <View style={styles.inline}>
          <View style={[styles.dot, { backgroundColor: statusTone }]} />
          <Text variant="caption" color="textSecondary">
            {i18n.t(`clock.${status}`)}
          </Text>
        </View>
      ),
      href: '/clock',
      a11y: `${i18n.t('home.clockTitle')}: ${formatDuration(Math.floor(worked / 60_000))}, ${i18n.t(`clock.${status}`)}`,
    },
    {
      key: 'week',
      label: i18n.t('clock.thisWeek'),
      value: (
        <Text variant="headline" tabular>
          {formatDuration(week)}
        </Text>
      ),
      sub: <Meter value={week / (40 * 60)} color={t.colors.primary} height={4} />,
      href: '/more/timesheets',
      a11y: `${i18n.t('clock.thisWeek')}: ${formatDuration(week)}`,
    },
    ...(canApprove && widgets.includes('approvals')
      ? [
          {
            key: 'approvals',
            label: i18n.t('home.approvalsTitle'),
            value: (
              <Text variant="headline" tabular color={pending > 0 ? 'warning' : 'text'}>
                {i18n.number(pending)}
              </Text>
            ),
            sub: (
              <Text variant="caption" color="textSecondary">
                {i18n.t('module.approvals')}
              </Text>
            ),
            href: '/more/approvals' as Href,
            a11y: `${i18n.t('home.approvalsTitle')}: ${pending}`,
          },
        ]
      : []),
    {
      key: 'shift',
      label: i18n.t('home.nextShift'),
      value: (
        <Text variant="headline" tabular numberOfLines={1}>
          {nextShift === undefined ? '—' : i18n.time(nextShift.start, tz)}
        </Text>
      ),
      sub: (
        <Text variant="caption" color="textSecondary" numberOfLines={1}>
          {nextShift === undefined ? i18n.t('home.noShift') : nextShift.date === today ? i18n.t('common.today') : i18n.date(nextShift.date, { weekday: 'short', month: 'short', day: 'numeric' })}
        </Text>
      ),
      href: '/schedule',
      a11y: `${i18n.t('home.nextShift')}: ${nextShift === undefined ? i18n.t('home.noShift') : i18n.time(nextShift.start, tz)}`,
    },
    ...(vacation !== undefined
      ? [
          {
            key: 'leave',
            label: vacation.name,
            value: (
              <Text variant="headline" tabular>
                {i18n.number(vacation.available)}
                <Text variant="caption" color="textTertiary">{` / ${i18n.number(vacation.entitled)}`}</Text>
              </Text>
            ),
            sub: <Meter value={vacation.available / vacation.entitled} color={t.colors.success} height={4} />,
            href: '/more/timeoff' as Href,
            a11y: `${vacation.name}: ${vacation.available}`,
          },
        ]
      : []),
  ];

  return (
    <View style={[styles.strip, { backgroundColor: t.colors.surface, borderRadius: t.shape.card - 6 }]}>
      {cells.map((c, i) => (
        <Touchable
          key={c.key}
          onPress={() => router.navigate(c.href)}
          feedback="highlight"
          accessibilityRole="link"
          accessibilityLabel={c.a11y}
          style={[styles.cell, i > 0 && { borderLeftWidth: StyleSheet.hairlineWidth, borderLeftColor: t.colors.separator }]}
        >
          <Text variant="caption" color="textSecondary" weight="600" numberOfLines={1} style={styles.eyebrow}>
            {c.label}
          </Text>
          {c.value}
          {c.sub}
        </Touchable>
      ))}
    </View>
  );
}

/** Compact panel: header row + dense rows. */
function Panel({ title, icon, action, children }: { title: string; icon: IconName; action?: { label: string; href: Href }; children: ReactNode }) {
  const t = useTheme();
  return (
    <View style={[styles.panel, { backgroundColor: t.colors.surface, borderRadius: t.shape.card - 6 }]}>
      <View style={[styles.panelHead, { borderBottomColor: t.colors.separator }]}>
        <Icon name={icon} size={16} color={t.colors.primary} />
        <Text variant="subhead" weight="700" style={{ flex: 1 }} accessibilityRole="header">
          {title}
        </Text>
        {action !== undefined && (
          <Touchable onPress={() => router.navigate(action.href)} feedback="none" hitSlop={8} accessibilityRole="link" accessibilityLabel={action.label}>
            <Text variant="footnote" color="primary" weight="600">
              {action.label}
            </Text>
          </Touchable>
        )}
      </View>
      {children}
    </View>
  );
}

function Row({ children, last, onPress, label }: { children: ReactNode; last?: boolean; onPress?: () => void; label?: string }) {
  const t = useTheme();
  const style = [styles.row, !last && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }];
  return onPress === undefined ? (
    <View style={style}>{children}</View>
  ) : (
    <Touchable onPress={onPress} feedback="highlight" accessibilityLabel={label} style={style}>
      {children}
    </Touchable>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <View style={styles.row}>
      <Text variant="footnote" color="textSecondary">
        {text}
      </Text>
    </View>
  );
}

function PanelFor({ widget, session }: { widget: HomeWidget; session: SessionInfo }) {
  switch (widget) {
    case 'clock':
      return null; // covered by the summary strip
    case 'approvals':
      return <ApprovalsPanel />;
    case 'next_shift':
      return <ShiftsPanel session={session} />;
    case 'team_pulse':
      return <TeamPanel />;
    case 'org_metrics':
      return <OrgPanel />;
    case 'my_work':
      return <WorkPanel session={session} />;
    case 'balances':
      return <BalancesPanel />;
  }
}

const KIND_TONE: Readonly<Record<string, Tone>> = { timesheet: 'primary', leave: 'success', day_off: 'info', overtime: 'warning', correction: 'danger' };

function ApprovalsPanel() {
  const i18n = useI18n();
  const now = useNow(60_000);
  const approvals = useApprovals();
  const items = (approvals.data ?? []).filter((a) => a.canDecide).sort((a, b) => a.submittedAt.localeCompare(b.submittedAt)).slice(0, 5);
  const total = (approvals.data ?? []).filter((a) => a.canDecide).length;
  return (
    <Panel title={`${i18n.t('home.approvalsTitle')} · ${total}`} icon="approvals" action={{ label: i18n.t('common.seeAll'), href: '/more/approvals' }}>
      {items.length === 0 ? (
        <Empty text={i18n.t('home.approvalsNone')} />
      ) : (
        items.map((a, i) => {
          const d = describeRequest(a, i18n);
          return (
            <Row key={a.id} last={i === items.length - 1} onPress={() => router.navigate('/more/approvals')} label={`${a.requester.name}, ${d.summary}`}>
              <Avatar initials={a.requester.initials} hue={a.requester.hue} size={28} />
              <Text variant="subhead" weight="600" style={styles.name} numberOfLines={1}>
                {a.requester.name}
              </Text>
              <Text variant="footnote" color="textSecondary" style={{ flex: 1 }} numberOfLines={1}>
                {d.summary} · {d.detail}
              </Text>
              <Pill label={i18n.t(`approvals.kind.${a.kind}`)} tone={KIND_TONE[a.kind] ?? 'neutral'} />
              <Text variant="caption" color="textTertiary" style={styles.time}>
                {i18n.relative(a.submittedAt, now)}
              </Text>
            </Row>
          );
        })
      )}
    </Panel>
  );
}

function ShiftsPanel({ session }: { session: SessionInfo }) {
  const t = useTheme();
  const i18n = useI18n();
  const tz = session.organization.timeZone;
  const now = useNow(60_000);
  const today = localDateKey(now, tz);
  const shifts = useShifts(today, 7);
  const upcoming = (shifts.data ?? []).filter((s) => Date.parse(s.end) > now.getTime()).slice(0, 3);
  return (
    <Panel title={i18n.t('home.nextShift')} icon="schedule" action={{ label: i18n.t('common.seeAll'), href: '/schedule' }}>
      {upcoming.length === 0 ? (
        <Empty text={i18n.t('home.noShift')} />
      ) : (
        upcoming.map((s, i) => (
          <Row key={s.id} last={i === upcoming.length - 1}>
            <Text variant="subhead" weight="600" style={styles.name}>
              {s.date === today ? i18n.t('common.today') : i18n.date(s.date, { weekday: 'short', month: 'short', day: 'numeric' })}
            </Text>
            <Text variant="subhead" tabular style={styles.range}>
              {i18n.time(s.start, tz)} – {i18n.time(s.end, tz)}
            </Text>
            <Text variant="footnote" color="textSecondary" style={{ flex: 1 }} numberOfLines={1}>
              {s.location}
              {s.holiday !== undefined ? ` · ${s.holiday.name}` : ''}
            </Text>
            <View style={styles.inline}>
              {s.teammates.slice(0, 4).map((p, k) => (
                <View key={p.id} style={{ marginLeft: k === 0 ? 0 : -6, borderWidth: 2, borderColor: t.colors.surface, borderRadius: 999 }}>
                  <Avatar initials={p.initials} hue={p.hue} size={22} />
                </View>
              ))}
            </View>
          </Row>
        ))
      )}
    </Panel>
  );
}

function TeamPanel() {
  const t = useTheme();
  const i18n = useI18n();
  const pulse = useTeamPulse();
  const p = pulse.data;
  const stats: { label: string; value: number; color: string }[] = [
    { label: i18n.t('clock.working'), value: p?.onShift ?? 0, color: t.colors.success },
    { label: i18n.t('clock.on_break'), value: p?.onBreak ?? 0, color: t.colors.warning },
    { label: i18n.t('home.late'), value: p?.late ?? 0, color: t.colors.danger },
    { label: i18n.t('clock.off'), value: p?.off ?? 0, color: t.colors.textTertiary },
  ];
  return (
    <Panel title={i18n.t('home.teamPulse')} icon="team" action={{ label: i18n.t('common.seeAll'), href: '/more/team' }}>
      <View style={styles.statRow}>
        {stats.map((s) => (
          <View key={s.label} style={styles.stat} accessible accessibilityLabel={`${s.label}: ${s.value}`}>
            <Text variant="title2" tabular>
              {p === undefined ? '–' : s.value}
            </Text>
            <View style={styles.inline}>
              <View style={[styles.dot, { backgroundColor: s.color }]} />
              <Text variant="caption" color="textSecondary">
                {s.label}
              </Text>
            </View>
          </View>
        ))}
      </View>
    </Panel>
  );
}

function OrgPanel() {
  const t = useTheme();
  const i18n = useI18n();
  const report = useExecutiveReport(4);
  const r = report.data;
  const metrics = r === undefined ? [] : [
    { label: i18n.t('reports.attendanceRate'), value: r.current.attendanceRate, color: t.colors.success },
    { label: i18n.t('reports.punctuality'), value: r.current.punctualityRate, color: t.colors.primary },
    { label: i18n.t('reports.overtimeShare'), value: r.current.overtimeShare, color: t.colors.warning },
  ];
  return (
    <Panel title={i18n.t('home.orgMetrics')} icon="reports" action={{ label: i18n.t('common.seeAll'), href: '/more/reports' }}>
      <View style={styles.statRow}>
        {metrics.map((m) => (
          <View key={m.label} style={[styles.stat, { gap: 6 }]} accessible accessibilityLabel={`${m.label}: ${i18n.number(m.value, { style: 'percent', maximumFractionDigits: 1 })}`}>
            <View style={styles.between}>
              <Text variant="caption" color="textSecondary">
                {m.label}
              </Text>
              <Text variant="subhead" weight="700" tabular>
                {i18n.number(m.value, { style: 'percent', maximumFractionDigits: 1 })}
              </Text>
            </View>
            <Meter value={m.value} color={m.color} height={4} />
          </View>
        ))}
        {r === undefined && <Empty text={i18n.t('common.loading')} />}
      </View>
    </Panel>
  );
}

function WorkPanel({ session }: { session: SessionInfo }) {
  const i18n = useI18n();
  const tasks = useTasks();
  const setDone = useSetTaskDone();
  const today = localDateKey(new Date(), session.organization.timeZone);
  const open = (tasks.data ?? []).filter((x) => x.status !== 'done').sort(compareTasks).slice(0, 6);
  const tone: Record<string, Tone | null> = { urgent: 'danger', high: 'warning', normal: null, low: null };
  return (
    <Panel title={i18n.t('home.myWork')} icon="work" action={{ label: i18n.t('common.seeAll'), href: '/work' }}>
      {open.length === 0 ? (
        <Empty text={i18n.t('home.caughtUp')} />
      ) : (
        open.map((task, i) => {
          const overdue = bucketOf(task, today) === 'overdue';
          const pr = tone[task.priority];
          return (
            <Row key={task.id} last={i === open.length - 1}>
              <Checkbox checked={false} onToggle={() => setDone.mutate({ id: task.id, done: true })} label={i18n.t('work.markDone', { title: task.title })} />
              <Text variant="subhead" style={{ flex: 1 }} numberOfLines={1}>
                {task.title}
              </Text>
              {pr !== null && pr !== undefined && <Pill label={i18n.t(`work.priority.${task.priority}`)} tone={pr} />}
              <Text variant="caption" color={overdue ? 'danger' : 'textTertiary'} style={styles.time}>
                {task.due === undefined ? i18n.t('work.noDue') : task.due === today ? i18n.t('common.today') : i18n.date(task.due, { month: 'short', day: 'numeric' })}
              </Text>
            </Row>
          );
        })
      )}
    </Panel>
  );
}

function BalancesPanel() {
  const t = useTheme();
  const i18n = useI18n();
  const balances = useBalances();
  return (
    <Panel title={i18n.t('home.balances')} icon="timeoff" action={{ label: i18n.t('timeoff.new'), href: '/request-time-off' }}>
      <View style={styles.statRow}>
        {(balances.data ?? []).map((b) => (
          <View key={b.leaveTypeId} style={[styles.stat, { gap: 6 }]} accessible accessibilityLabel={`${b.name}: ${b.available} / ${b.entitled}`}>
            <View style={styles.between}>
              <Text variant="caption" color="textSecondary">
                {b.name}
              </Text>
              <Text variant="subhead" weight="700" tabular>
                {i18n.number(b.available)}
                <Text variant="caption" color="textTertiary">{` / ${i18n.number(b.entitled)}`}</Text>
              </Text>
            </View>
            <Meter value={b.available / b.entitled} color={`hsl(${b.hue}, 65%, ${t.scheme === 'dark' ? 62 : 45}%)`} height={4} />
          </View>
        ))}
      </View>
    </Panel>
  );
}

const styles = StyleSheet.create({
  header: { flexDirection: 'row', alignItems: 'flex-end', gap: 16, flexWrap: 'wrap' },
  eyebrow: { textTransform: 'uppercase', letterSpacing: 0.6 },
  actions: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  strip: { flexDirection: 'row', overflow: 'hidden' },
  cell: { flex: 1, paddingHorizontal: 16, paddingVertical: 12, gap: 4, minWidth: 0 },
  panel: { overflow: 'hidden' },
  panelHead: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 16, paddingVertical: 10, borderBottomWidth: StyleSheet.hairlineWidth },
  row: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 16, minHeight: 44, paddingVertical: 6 },
  name: { width: 150 },
  range: { width: 170 },
  time: { minWidth: 64, textAlign: 'right' },
  inline: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  dot: { width: 7, height: 7, borderRadius: 4 },
  statRow: { flexDirection: 'row', paddingHorizontal: 16, paddingVertical: 12, gap: 24 },
  stat: { flex: 1, gap: 2 },
  between: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 },
  footer: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 4 },
});
