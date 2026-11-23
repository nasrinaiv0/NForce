import { UserId, formatDuration, type ApprovalStatus, type DateKey } from '@nforce/core';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState, type ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Avatar, Meter, Pill, type Tone } from '@/components/Display';
import { Icon, type IconName } from '@/components/Icon';
import { ListControls, useListView } from '@/components/ListView';
import { requestTitle } from '@/components/requestText';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, SectionHeader } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { directReportFields, myRequestFields } from '@/data/listFields';
import { errorMessage, useOffboardEmployee, useProfile, useSession } from '@/data/queries';
import type { PersonProfile } from '@/data/types';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<ApprovalStatus, Tone>> = { pending: 'warning', approved: 'success', returned: 'danger', cancelled: 'neutral' };
const LEAVE_HUES = ['#2F5BEA', '#1F9D61', '#8E44C9', '#C2410C'];

/**
 * Employee profile. The server decides what each viewer gets: everyone sees
 * the directory card; leave credits, attendance and overtime need access to
 * this person; confidential HR details are only for the person, HR and owners.
 *
 * Desktop: profile and details on the left, detailed information on the
 * right, direct reports below. Phones stack the same sections.
 */
export default function PersonScreen() {
  const i18n = useI18n();
  const { id } = useLocalSearchParams<{ id: string }>();
  const profile = useProfile(UserId(String(id)));
  const p = profile.data;
  if (profile.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void profile.refetch()} message={errorMessage(profile.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (p === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={3} height={90} />
      </Screen>
    );
  }
  return <Profile p={p} i18n={i18n} />;
}

function Profile({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const { isDesktop } = useResponsive();
  const session = useSession();
  const isMe = session.data?.user.id === p.person.id;

  const left = (
    <View style={{ gap: t.space.lg }}>
      <IdentityCard p={p} i18n={i18n} />
      <DetailsCard p={p} i18n={i18n} />
      <ReportingLineCard p={p} i18n={i18n} />
      <ManageCard p={p} i18n={i18n} isMe={isMe} />
    </View>
  );
  const right = (
    <View style={{ gap: t.space.lg }}>
      {p.leaveCredits !== undefined && <LeaveCreditsCard p={p} i18n={i18n} />}
      {p.attendance !== undefined && <AttendanceCard p={p} i18n={i18n} />}
      {p.sensitive !== undefined ? (
        <>
          <EmploymentCard p={p} i18n={i18n} />
          <PersonalCard p={p} i18n={i18n} />
        </>
      ) : (
        <Notice icon="shield" text={i18n.t('people.restricted')} />
      )}
      {p.leaveHistory !== undefined && <LeaveHistoryCard p={p} i18n={i18n} />}
    </View>
  );

  return (
    <Screen maxWidth={1240}>
      <Stack.Screen options={{ title: p.person.name }} />
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xl }]}>
          <View style={{ width: 340 }}>{left}</View>
          <View style={{ flex: 1, minWidth: 0 }}>{right}</View>
        </View>
      ) : (
        <>
          <IdentityCard p={p} i18n={i18n} />
          {p.leaveCredits !== undefined && <LeaveCreditsCard p={p} i18n={i18n} />}
          {p.attendance !== undefined && <AttendanceCard p={p} i18n={i18n} />}
          <DetailsCard p={p} i18n={i18n} />
          {p.sensitive !== undefined ? (
            <>
              <EmploymentCard p={p} i18n={i18n} />
              <PersonalCard p={p} i18n={i18n} />
            </>
          ) : (
            <Notice icon="shield" text={i18n.t('people.restricted')} />
          )}
          {p.leaveHistory !== undefined && <LeaveHistoryCard p={p} i18n={i18n} />}
          <ReportingLineCard p={p} i18n={i18n} />
          <ManageCard p={p} i18n={i18n} isMe={isMe} />
        </>
      )}
      <DirectReports p={p} i18n={i18n} columns={isDesktop ? 3 : 1} />
    </Screen>
  );
}

// ------------------------------------------------------------------ left

function IdentityCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const { isDesktop } = useResponsive();
  return (
    <Card style={[styles.identity, { gap: t.space.md }, !isDesktop && styles.identityRow]}>
      <View style={[styles.photoRing, { borderColor: t.colors.primaryContainer }]}>
        <Avatar initials={p.person.initials} hue={p.person.hue} size={isDesktop ? 112 : 72} />
      </View>
      <View style={[{ gap: 4 }, isDesktop ? styles.center : { flex: 1 }]}>
        <Text variant={isDesktop ? 'title' : 'title2'} style={isDesktop ? styles.textCenter : undefined} accessibilityRole="header">
          {p.person.name}
        </Text>
        <Text variant="subhead" color="textSecondary" style={isDesktop ? styles.textCenter : undefined}>
          {p.person.title}
        </Text>
        <View style={[styles.row, isDesktop && styles.centerRow]}>
          <Pill label={i18n.t(`role.${p.role}`)} tone="primary" icon="shield" />
          {p.sensitive !== undefined && <Pill label={p.sensitive.employeeId} tone="neutral" />}
        </View>
        <Text variant="footnote" color="textTertiary" style={isDesktop ? styles.textCenter : undefined}>
          {[p.department, p.teamName].filter(Boolean).join(' · ')}
        </Text>
      </View>
    </Card>
  );
}

function DetailsCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const weekday = (n: number) => i18n.date(`2024-01-0${n}` as DateKey, { weekday: 'long' });
  return (
    <Card style={{ gap: 2 }}>
      <SectionHeader title={i18n.t('people.contact')} />
      <InfoRow icon="mail" label={i18n.t('people.workEmail')} value={p.workEmail} />
      {p.sensitive !== undefined && <InfoRow icon="phone" label={i18n.t('people.mobile')} value={p.sensitive.mobile} />}
      <InfoRow icon="location" label={i18n.t('people.location')} value={p.location} />
      <InfoRow icon="clock" label={i18n.t('people.shift')} value={p.shift} />
      <InfoRow icon="restDay" label={i18n.t('people.restDays')} value={p.restDays.map(weekday).join(', ')} last />
    </Card>
  );
}

function ReportingLineCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  return (
    <Card style={{ gap: t.space.sm }}>
      <SectionHeader title={i18n.t('people.reportingLine')} />
      {p.chain.length === 0 ? (
        <InfoRow icon="hierarchy" label={i18n.t('people.topOfOrg')} value="" last />
      ) : (
        p.chain.map((m, i) => (
          <PersonRow key={m.id} person={m} subtitle={m.title} onPress={() => router.push({ pathname: '/more/person/[id]', params: { id: m.id } })} dim={i > 0} />
        ))
      )}
    </Card>
  );
}

function ManageCard({ p, i18n, isMe }: { p: PersonProfile; i18n: I18n; isMe: boolean }) {
  const t = useTheme();
  const session = useSession();
  const offboard = useOffboardEmployee();
  const [confirming, setConfirming] = useState(false);
  const canSeeTimesheet = isMe || p.overtime !== undefined;
  const managesPeople = session.data?.capabilities.managePeople === true || session.data?.capabilities.offboard === true;
  const blocked = !isMe && !p.access.canEdit && !p.access.canOffboard && managesPeople;
  if (!canSeeTimesheet && !p.access.canEdit && !p.access.canOffboard && !blocked) return null;
  return (
    <Card style={{ gap: t.space.md }}>
      {(p.access.canEdit || p.access.canOffboard) && <Text variant="headline">{i18n.t('people.manage')}</Text>}
      <View style={styles.row}>
        {canSeeTimesheet && (
          <Button title={i18n.t('timesheet.title')} icon="timesheets" variant="tonal" size="small" onPress={() => router.push({ pathname: '/more/timesheets', params: { user: p.person.id } })} />
        )}
        {p.access.canEdit && (
          <Button title={i18n.t('people.edit')} icon="settings" variant="tonal" size="small" onPress={() => router.push({ pathname: '/employee-form', params: { id: p.person.id } })} />
        )}
        {p.access.canOffboard && !confirming && <Button title={i18n.t('people.offboard')} icon="logout" variant="destructive" size="small" onPress={() => setConfirming(true)} />}
      </View>
      {blocked && <Notice icon="shield" text={i18n.t(p.role === 'owner' ? 'people.protected' : 'people.noAccessHere')} />}
      {confirming && (
        <View style={[styles.confirm, { backgroundColor: t.colors.dangerContainer, borderRadius: t.shape.control }]}>
          <Text variant="footnote" style={{ color: t.colors.danger }}>
            {i18n.t('people.offboardConfirm', { name: p.person.name, count: p.directReports.length })}
          </Text>
          <View style={styles.row}>
            <Button title={i18n.t('common.cancel')} variant="plain" size="small" onPress={() => setConfirming(false)} />
            <Button
              title={i18n.t('people.offboard')}
              variant="destructive"
              size="small"
              loading={offboard.isPending}
              onPress={() =>
                offboard.mutate(p.person.id, {
                  onSuccess: () => {
                    haptics.success();
                    router.back();
                  },
                  onError: () => haptics.error(),
                })
              }
            />
          </View>
        </View>
      )}
      {offboard.isError && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {errorMessage(offboard.error, i18n.t('common.errorBody'))}
        </Text>
      )}
    </Card>
  );
}

// ------------------------------------------------------------------ right

function LeaveCreditsCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const credits = p.leaveCredits ?? [];
  return (
    <Card style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('people.leaveCredits')} />
      <View style={[styles.tiles, { gap: t.space.md }]}>
        {credits.map((c, i) => {
          const color = LEAVE_HUES[i % LEAVE_HUES.length] ?? t.colors.primary;
          return (
            <View
              key={c.leaveTypeId}
              style={[styles.tile, { backgroundColor: t.colors.fill, borderRadius: t.shape.control }]}
              accessible
              accessibilityLabel={`${c.name}: ${i18n.t('people.creditsOf', { available: c.available, entitled: c.entitled })}`}
            >
              <View style={styles.rowBetween}>
                <Text variant="subhead" weight="600">
                  {c.name}
                </Text>
                <View style={[styles.swatch, { backgroundColor: color }]} />
              </View>
              <View style={styles.baseline}>
                <Text variant="title" tabular>
                  {c.available}
                </Text>
                <Text variant="footnote" color="textSecondary">
                  {i18n.t('people.ofDays', { entitled: c.entitled })}
                </Text>
              </View>
              <Meter value={c.entitled > 0 ? c.available / c.entitled : 0} color={color} />
              <Text variant="caption" color="textSecondary">
                {i18n.t('people.usedPending', { used: c.used, pending: c.pending })}
              </Text>
            </View>
          );
        })}
      </View>
    </Card>
  );
}

function AttendanceCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const { isDesktop } = useResponsive();
  const a = p.attendance;
  if (a === undefined) return null;
  const m = a.metrics;
  const pct = (x: number) => `${Math.round(x * 100)}%`;
  const stats: { label: string; value: string; icon: IconName; tone?: string }[] = [
    { label: i18n.t('people.attendanceRate'), value: pct(m.attendanceRate), icon: 'check', tone: m.attendanceRate < 0.95 ? t.colors.warning : t.colors.success },
    { label: i18n.t('people.punctuality'), value: pct(m.punctualityRate), icon: 'clock' },
    { label: i18n.t('people.lateDays'), value: String(m.lateDays), icon: 'warning', ...(m.lateDays > 0 ? { tone: t.colors.warning } : {}) },
    { label: i18n.t('people.absences'), value: String(m.absentDays), icon: 'close', ...(m.absentDays > 0 ? { tone: t.colors.danger } : {}) },
    { label: i18n.t('people.worked'), value: formatDuration(m.workedMinutes), icon: 'timesheets' },
    ...(p.overtime !== undefined
      ? [{ label: i18n.t('people.otMonth'), value: formatDuration(p.overtime.workedMinutes), icon: 'overtime' as const }]
      : []),
  ];
  return (
    <Card style={{ gap: t.space.md }}>
      <SectionHeader title={i18n.t('people.attendance30', { from: i18n.date(a.from, { month: 'short', day: 'numeric' }), to: i18n.date(a.to, { month: 'short', day: 'numeric' }) })} />
      <View style={[styles.tiles, { gap: t.space.sm }]}>
        {stats.map((s) => (
          <View key={s.label} style={[styles.stat, { backgroundColor: t.colors.fill, borderRadius: t.shape.control }]} accessible accessibilityLabel={`${s.label}: ${s.value}`}>
            <Icon name={s.icon} size={15} color={s.tone ?? t.colors.primary} />
            <Text variant={isDesktop ? 'title2' : 'headline'} tabular numberOfLines={1} style={s.tone !== undefined ? { color: s.tone } : undefined}>
              {s.value}
            </Text>
            <Text variant="caption" color="textSecondary" numberOfLines={1}>
              {s.label}
            </Text>
          </View>
        ))}
      </View>
      {p.overtime !== undefined && p.overtime.workedMinutes > 0 && (
        <Text variant="caption" color="textSecondary">
          {i18n.t('people.otDetail', { approved: formatDuration(p.overtime.approvedMinutes), pending: formatDuration(p.overtime.pendingMinutes) })}
        </Text>
      )}
    </Card>
  );
}

function EmploymentCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const s = p.sensitive;
  if (s === undefined) return null;
  const long = { year: 'numeric', month: 'long', day: 'numeric' } as const;
  const months = s.tenureMonths;
  return (
    <Card style={{ gap: t.space.sm }}>
      <View style={styles.rowBetween}>
        <SectionHeader title={i18n.t('people.employment')} />
        <Pill label={i18n.t('people.confidential')} tone="warning" icon="shield" />
      </View>
      <View style={styles.grid}>
        <Field label={i18n.t('people.employeeId')} value={s.employeeId} />
        <Field label={i18n.t('people.employmentType')} value={i18n.t(`people.type.${s.employmentType}`)} />
        <Field label={i18n.t('people.hireDate')} value={i18n.date(s.hireDate, long)} />
        <Field label={i18n.t('people.tenure')} value={i18n.t('people.tenureValue', { years: Math.floor(months / 12), months: months % 12 })} />
        <Field label={i18n.t('people.regularizedOn')} value={s.regularizedOn !== undefined ? i18n.date(s.regularizedOn, long) : '—'} />
        <Field label={i18n.t('people.arrangement')} value={i18n.t(`people.arr.${s.workArrangement}`)} />
        <Field label={i18n.t('people.payGrade')} value={s.payGrade} />
        <Field label={i18n.t('people.department')} value={p.department} />
      </View>
      <Text variant="caption" color="textTertiary">
        {i18n.t('people.confidentialFooter')}
      </Text>
    </Card>
  );
}

function PersonalCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const s = p.sensitive;
  if (s === undefined) return null;
  return (
    <Card style={{ gap: t.space.sm }}>
      <SectionHeader title={i18n.t('people.personal')} />
      <View style={styles.grid}>
        <Field label={i18n.t('people.birthday')} value={i18n.date(s.birthday, { month: 'long', day: 'numeric' })} />
        <Field label={i18n.t('people.personalEmail')} value={s.personalEmail} />
        <Field label={i18n.t('people.address')} value={s.address} />
        <Field label={i18n.t('people.emergency')} value={`${s.emergencyContact.name} · ${s.emergencyContact.relationship}\n${s.emergencyContact.phone}`} />
      </View>
      <View style={[styles.divider, { backgroundColor: t.colors.separator }]} />
      <Text variant="footnote" weight="700" color="textSecondary">
        {i18n.t('people.govIds')}
      </Text>
      <View style={styles.grid}>
        {s.governmentIds.map((g) => (
          <Field key={g.kind} label={i18n.t(`people.gov.${g.kind}`)} value={g.masked} mono />
        ))}
      </View>
    </Card>
  );
}

function LeaveHistoryCard({ p, i18n }: { p: PersonProfile; i18n: I18n }) {
  const t = useTheme();
  const list = useListView({ id: 'profile-leave', fields: useMemo(() => myRequestFields(i18n), [i18n]), defaultSort: { key: 'submitted', direction: 'desc' } });
  const items = list.apply(p.leaveHistory ?? []);
  return (
    <Card style={{ gap: t.space.sm }}>
      <SectionHeader title={i18n.t('people.recentLeave')} />
      {(p.leaveHistory ?? []).length > 1 && <ListControls state={list} resultCount={items.length} />}
      {items.length === 0 ? (
        <Text variant="subhead" color="textSecondary">
          {i18n.t('people.noLeave')}
        </Text>
      ) : (
        items.map((r, idx) => {
          const { title, subtitle } = requestTitle(r, i18n);
          return (
            <View key={r.id} style={[styles.rowBetween, styles.listRow, idx < items.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
              <View style={{ flex: 1, gap: 2 }}>
                <Text variant="subhead" weight="600">
                  {title}
                </Text>
                <Text variant="footnote" color="textSecondary">
                  {subtitle}
                </Text>
              </View>
              <Pill label={i18n.t(`approvals.status.${r.status}`)} tone={STATUS_TONE[r.status]} />
            </View>
          );
        })
      )}
    </Card>
  );
}

// ------------------------------------------------------------------ bottom

function DirectReports({ p, i18n, columns }: { p: PersonProfile; i18n: I18n; columns: number }) {
  const t = useTheme();
  const list = useListView({
    id: 'profile-reports',
    fields: useMemo(() => directReportFields(i18n), [i18n]),
    defaultSort: { key: 'name', direction: 'asc' },
    searchText: (r) => [r.person.name, r.person.title, r.teamName],
  });
  const reports = list.apply(p.directReports);
  if (p.directReports.length === 0) return null;
  return (
    <View style={{ gap: t.space.sm }}>
      <SectionHeader title={i18n.t('people.directReports', { count: p.directReports.length })} />
      {p.directReports.length > 1 && <ListControls state={list} searchPlaceholder={i18n.t('people.search')} resultCount={reports.length} />}
      <View style={[styles.reports, { gap: t.space.md }]}>
        {reports.map((r) => (
          <Touchable
            key={r.person.id}
            onPress={() => router.push({ pathname: '/more/person/[id]', params: { id: r.person.id } })}
            feedback="highlight"
            accessibilityRole="button"
            accessibilityLabel={`${r.person.name}, ${r.person.title}`}
            style={[styles.reportCard, { backgroundColor: t.colors.surface, borderRadius: t.shape.card, flexBasis: columns === 1 ? '100%' : `${100 / columns - 2}%` }]}
          >
            <Avatar initials={r.person.initials} hue={r.person.hue} size={44} />
            <View style={{ flex: 1, gap: 2 }}>
              <Text variant="subhead" weight="700" numberOfLines={1}>
                {r.person.name}
              </Text>
              <Text variant="footnote" color="textSecondary" numberOfLines={1}>
                {r.person.title}
              </Text>
              <Text variant="caption" color="textTertiary" numberOfLines={1}>
                {[r.teamName ?? i18n.t(`role.${r.role}`), r.reports > 0 ? i18n.plural('people.reportsCount', r.reports) : undefined].filter(Boolean).join(' · ')}
              </Text>
            </View>
            <Icon name="chevron" size={13} color={t.colors.textTertiary} />
          </Touchable>
        ))}
      </View>
    </View>
  );
}

// ------------------------------------------------------------------ bits

function InfoRow({ icon, label, value, last = false }: { icon: IconName; label: string; value: string; last?: boolean }) {
  const t = useTheme();
  return (
    <View style={[styles.infoRow, !last && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]} accessible accessibilityLabel={`${label}: ${value}`}>
      <Icon name={icon} size={16} color={t.colors.textSecondary} />
      <View style={{ flex: 1 }}>
        <Text variant="caption" color="textSecondary">
          {label}
        </Text>
        {value.length > 0 && (
          <Text variant="subhead" selectable>
            {value}
          </Text>
        )}
      </View>
    </View>
  );
}

function PersonRow({ person, subtitle, onPress, dim }: { person: PersonProfile['person']; subtitle: string; onPress: () => void; dim: boolean }) {
  return (
    <Touchable onPress={onPress} feedback="highlight" accessibilityRole="button" accessibilityLabel={`${person.name}, ${subtitle}`} style={[styles.personRow, dim && { opacity: 0.75 }]}>
      <Avatar initials={person.initials} hue={person.hue} size={32} />
      <View style={{ flex: 1 }}>
        <Text variant="subhead" weight="600" numberOfLines={1}>
          {person.name}
        </Text>
        <Text variant="caption" color="textSecondary" numberOfLines={1}>
          {subtitle}
        </Text>
      </View>
    </Touchable>
  );
}

function Field({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <View style={styles.field} accessible accessibilityLabel={`${label}: ${value}`}>
      <Text variant="caption" color="textSecondary">
        {label}
      </Text>
      <Text variant="subhead" weight="500" tabular={mono} selectable>
        {value}
      </Text>
    </View>
  );
}

function Notice({ icon, text }: { icon: IconName; text: string }): ReactNode {
  const t = useTheme();
  return (
    <Card style={[styles.row, { backgroundColor: t.colors.fill }]}>
      <Icon name={icon} size={18} color={t.colors.textSecondary} />
      <Text variant="footnote" color="textSecondary" style={{ flex: 1 }}>
        {text}
      </Text>
    </Card>
  );
}

const styles = StyleSheet.create({
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  identity: { alignItems: 'center', paddingVertical: 24 },
  identityRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 16 },
  photoRing: { borderWidth: 4, borderRadius: 999, padding: 2 },
  center: { alignItems: 'center' },
  centerRow: { justifyContent: 'center' },
  textCenter: { textAlign: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  baseline: { flexDirection: 'row', alignItems: 'baseline', gap: 6 },
  tiles: { flexDirection: 'row', flexWrap: 'wrap' },
  tile: { flexGrow: 1, flexBasis: 180, padding: 14, gap: 6 },
  stat: { flexGrow: 1, flexBasis: '30%', minWidth: 96, padding: 12, gap: 2 },
  swatch: { width: 10, height: 10, borderRadius: 5 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', rowGap: 14, justifyContent: 'flex-start' },
  field: { flexBasis: '33%', minWidth: 140, flexGrow: 0, gap: 2, paddingRight: 12 },
  divider: { height: StyleSheet.hairlineWidth, marginVertical: 6 },
  infoRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 10 },
  personRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 6 },
  listRow: { paddingVertical: 10 },
  reports: { flexDirection: 'row', flexWrap: 'wrap' },
  reportCard: { flexDirection: 'row', alignItems: 'center', gap: 12, padding: 14, flexGrow: 1, minWidth: 240 },
  confirm: { padding: 12, gap: 8 },
});
