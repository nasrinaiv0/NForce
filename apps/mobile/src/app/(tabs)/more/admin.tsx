import { PERMISSIONS, ROLE_GRANTS, ROLE_TEMPLATES, mergeGrants, type Scope } from '@nforce/core';
import { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';

import { SegmentedControl } from '@/components/Controls';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { ListControls, useListView } from '@/components/ListView';
import { RateCard } from '@/components/PayBreakdown';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { auditFields, directoryFields, holidayFields } from '@/data/listFields';
import { errorMessage, useAdmin, useSession } from '@/data/queries';
import type { AdminOverview } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

type Tab = 'roles' | 'audit' | 'calendar';
const SCOPE_TONE: Readonly<Record<Scope, Tone>> = { self: 'neutral', team: 'info', department: 'primary', organization: 'warning' };

/** Administration: role/permission matrix, members, audit trail, holiday calendar and pay policy. */
export default function AdminScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const admin = useAdmin();
  const session = useSession();
  const [tab, setTab] = useState<Tab>('roles');
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const matrix = useMemo(() => ROLE_TEMPLATES.map((r) => ({ role: r, grants: mergeGrants(ROLE_GRANTS[r]) })), []);
  const memberList = useListView({
    id: 'admin-members',
    fields: useMemo(() => directoryFields(i18n), [i18n]),
    defaultSort: { key: 'name', direction: 'asc' },
    searchText: (m) => [m.person.name, m.person.title, m.department, i18n.t(`role.${m.role}`)],
  });
  const auditList = useListView({
    id: 'admin-audit',
    fields: useMemo(() => auditFields(i18n), [i18n]),
    defaultSort: { key: 'date', direction: 'desc' },
    searchText: (e) => [e.actor.name, e.action, e.detail],
  });
  const holidayList = useListView({
    id: 'admin-holidays',
    fields: useMemo(() => holidayFields<AdminOverview['holidays'][number]>(i18n), [i18n]),
    defaultSort: { key: 'date', direction: 'asc' },
    searchText: (h) => [h.name],
    quickFilters: [
      { value: 'all', label: i18n.t('list.all') },
      { value: 'regular', label: i18n.t('opt.holiday.regular'), test: (h) => h.kind === 'regular' },
      { value: 'special', label: i18n.t('opt.holiday.special'), test: (h) => h.kind === 'special' },
    ],
  });
  const permissionRows = useMemo(
    () => PERMISSIONS.map((perm) => ({ perm, area: perm.split('.')[0] ?? perm, roles: matrix.filter((m) => m.grants.has(perm)).map((m) => m.role) })),
    [matrix],
  );
  const permissionList = useListView({
    id: 'admin-permissions',
    fields: useMemo(
      () => [
        { key: 'perm', label: i18n.t('admin.permission'), kind: 'text' as const, get: (r: (typeof permissionRows)[number]) => r.perm },
        {
          key: 'area',
          label: i18n.t('field.area'),
          kind: 'choice' as const,
          get: (r: (typeof permissionRows)[number]) => r.area,
          options: [...new Set(PERMISSIONS.map((x) => x.split('.')[0] ?? x))].map((v) => ({ value: v, label: v })),
        },
        {
          key: 'roles',
          label: i18n.t('field.grantedTo'),
          kind: 'choice' as const,
          get: (r: (typeof permissionRows)[number]) => r.roles,
          options: ROLE_TEMPLATES.map((role) => ({ value: role, label: i18n.t(`role.${role}`) })),
          sortable: false,
        },
        { key: 'count', label: i18n.t('field.roleCount'), kind: 'number' as const, get: (r: (typeof permissionRows)[number]) => r.roles.length },
      ],
      [i18n],
    ),
    defaultSort: { key: 'area', direction: 'asc' },
    searchText: (r) => [r.perm],
  });
  const permissions = permissionList.apply(permissionRows);
  const members = memberList.apply(admin.data?.members ?? []);
  const audit = auditList.apply(admin.data?.audit ?? []);
  const holidays = holidayList.apply(admin.data?.holidays ?? []);

  if (admin.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void admin.refetch()} message={errorMessage(admin.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (admin.data === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={80} />
      </Screen>
    );
  }
  const a = admin.data;
  const scopeLabel = (s: Scope) => i18n.t(`admin.scope.${s}`);

  return (
    <Screen onRefresh={() => admin.refetch()} maxWidth={1400}>
      <SegmentedControl<Tab>
        segments={[
          { value: 'roles', label: i18n.t('admin.tab.roles') },
          { value: 'audit', label: i18n.t('admin.tab.audit') },
          { value: 'calendar', label: i18n.t('admin.tab.calendar') },
        ]}
        value={tab}
        onChange={setTab}
      />
      {tab === 'roles' && (
        <>
          <Card style={{ gap: t.space.md }}>
            <Text variant="headline">{i18n.t('admin.matrix')}</Text>
            <Text variant="footnote" color="textSecondary">
              {i18n.t('admin.matrixHint')}
            </Text>
            <ListControls state={permissionList} searchPlaceholder={i18n.t('list.search')} resultCount={permissions.length} />
            <ScrollView horizontal showsHorizontalScrollIndicator>
              <View>
                <View style={[styles.mRow, { borderBottomColor: t.colors.separator }]}>
                  <Text variant="caption" weight="700" color="textSecondary" style={styles.permCol}>
                    {i18n.t('admin.permission')}
                  </Text>
                  {matrix.map((m) => (
                    <Text key={m.role} variant="caption" weight="700" color="textSecondary" style={styles.roleCol} numberOfLines={1}>
                      {i18n.t(`role.${m.role}`)}
                    </Text>
                  ))}
                </View>
                {permissions.map(({ perm }) => (
                  <View key={perm} style={[styles.mRow, { borderBottomColor: t.colors.separator }]}>
                    <Text variant="footnote" style={styles.permCol} numberOfLines={1}>
                      {perm}
                    </Text>
                    {matrix.map((m) => {
                      const s = m.grants.get(perm);
                      return (
                        <View key={m.role} style={styles.roleCol} accessibilityLabel={`${i18n.t(`role.${m.role}`)} ${perm}: ${s === undefined ? '—' : scopeLabel(s)}`}>
                          {s === undefined ? <Text variant="footnote" color="textTertiary">—</Text> : <Pill label={scopeLabel(s)} tone={SCOPE_TONE[s]} />}
                        </View>
                      );
                    })}
                  </View>
                ))}
              </View>
            </ScrollView>
          </Card>
          <ListControls state={memberList} searchPlaceholder={i18n.t('people.search')} resultCount={members.length} />
          <ListSection title={i18n.t('admin.members', { count: a.members.length })}>
            {members.map((m, i) => (
              <ListRow
                key={m.person.id}
                title={m.person.name}
                subtitle={[m.person.title, m.manager !== undefined ? i18n.t('admin.reportsTo', { name: m.manager.name }) : undefined].filter(Boolean).join(' · ')}
                leading={<Avatar initials={m.person.initials} hue={m.person.hue} size={32} />}
                trailing={<Pill label={i18n.t(`role.${m.role}`)} tone="neutral" />}
                last={i === members.length - 1}
              />
            ))}
          </ListSection>
        </>
      )}
      {tab === 'audit' && (
        <>
          <ListControls state={auditList} searchPlaceholder={i18n.t('admin.auditSearch')} resultCount={audit.length} />
          <ListSection footer={i18n.t('admin.auditFooter')}>
            {audit.slice(0, 80).map((e, i) => (
              <ListRow
                key={e.id}
                title={`${e.action} · ${e.detail}`}
                subtitle={`${e.actor.name} · ${i18n.date(e.at.slice(0, 10) as never, { month: 'short', day: 'numeric' })} ${i18n.time(e.at, tz)}`}
                leading={<Avatar initials={e.actor.initials} hue={e.actor.hue} size={28} />}
                last={i === Math.min(audit.length, 80) - 1}
              />
            ))}
          </ListSection>
        </>
      )}
      {tab === 'calendar' && (
        <>
          <ListControls state={holidayList} resultCount={holidays.length} />
          <ListSection title={i18n.t('admin.holidays')} footer={i18n.t('admin.holidaysFooter')}>
            {holidays.map((h, i) => (
              <ListRow
                key={h.date}
                title={h.name}
                subtitle={i18n.date(h.date, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
                trailing={<Pill label={i18n.t(h.kind === 'regular' ? 'pay.day.regular_holiday' : 'pay.day.special')} tone={h.kind === 'regular' ? 'danger' : 'warning'} />}
                last={i === holidays.length - 1}
              />
            ))}
          </ListSection>
          <Card>
            <RateCard policy={a.payPolicy} i18n={i18n} />
          </Card>
        </>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  mRow: { flexDirection: 'row', alignItems: 'center', minHeight: 36, borderBottomWidth: StyleSheet.hairlineWidth },
  permCol: { width: 190, paddingRight: 8 },
  roleCol: { width: 104, alignItems: 'center' },
});
