import { PERMISSIONS, ROLE_GRANTS, ROLE_TEMPLATES, mergeGrants, queryList, type Scope } from '@nforce/core';
import { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';

import { SegmentedControl } from '@/components/Controls';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { ListToolbar } from '@/components/ListToolbar';
import { RateCard } from '@/components/PayBreakdown';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useAdmin, useSession } from '@/data/queries';
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
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<{ key: 'newest' | 'action'; direction: 'asc' | 'desc' }>({ key: 'newest', direction: 'desc' });
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const matrix = useMemo(() => ROLE_TEMPLATES.map((r) => ({ role: r, grants: mergeGrants(ROLE_GRANTS[r]) })), []);
  const audit = useMemo(
    () =>
      queryList(admin.data?.audit ?? [], {
        search: { text: search, fields: (e) => [e.actor.name, e.action, e.detail] },
        sort,
        accessors: { newest: (e) => e.at, action: (e) => e.action },
      }),
    [admin.data?.audit, search, sort],
  );

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
                {PERMISSIONS.map((perm) => (
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
          <ListSection title={i18n.t('admin.members', { count: a.members.length })}>
            {a.members.map((m, i) => (
              <ListRow
                key={m.person.id}
                title={m.person.name}
                subtitle={[m.person.title, m.manager !== undefined ? i18n.t('admin.reportsTo', { name: m.manager.name }) : undefined].filter(Boolean).join(' · ')}
                leading={<Avatar initials={m.person.initials} hue={m.person.hue} size={32} />}
                trailing={<Pill label={i18n.t(`role.${m.role}`)} tone="neutral" />}
                last={i === a.members.length - 1}
              />
            ))}
          </ListSection>
        </>
      )}
      {tab === 'audit' && (
        <>
          <ListToolbar
            search={search}
            onSearch={setSearch}
            searchPlaceholder={i18n.t('admin.auditSearch')}
            sortOptions={[
              { key: 'newest', label: i18n.t('admin.sort.time'), defaultDirection: 'desc' },
              { key: 'action', label: i18n.t('admin.sort.action') },
            ]}
            sort={sort}
            onSort={setSort}
            resultLabel={i18n.plural('list.results', audit.length)}
          />
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
          <ListSection title={i18n.t('admin.holidays')} footer={i18n.t('admin.holidaysFooter')}>
            {a.holidays.map((h, i) => (
              <ListRow
                key={h.date}
                title={h.name}
                subtitle={i18n.date(h.date, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
                trailing={<Pill label={i18n.t(h.kind === 'regular' ? 'pay.day.regular_holiday' : 'pay.day.special')} tone={h.kind === 'regular' ? 'danger' : 'warning'} />}
                last={i === a.holidays.length - 1}
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
