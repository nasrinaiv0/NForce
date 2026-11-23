import { facetCounts, formatDuration, queryList, type SortSpec } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Chip } from '@/components/Controls';
import { DataTable, type Column } from '@/components/DataTable';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { ListToolbar, type FilterOption, type SortOption } from '@/components/ListToolbar';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useSession, useTeam } from '@/data/queries';
import type { MemberStatus, TeamMember } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<MemberStatus, Tone>> = {
  working: 'success',
  on_break: 'warning',
  missed_punch: 'danger',
  late: 'danger',
  absent: 'danger',
  not_started: 'neutral',
  done: 'info',
  off: 'neutral',
};
const STATUS_ORDER: readonly MemberStatus[] = ['missed_punch', 'late', 'absent', 'working', 'on_break', 'not_started', 'done', 'off'];

type StatusFilter = 'all' | MemberStatus;
type SortKey = 'name' | 'status' | 'today' | 'week' | 'overtime' | 'night';

/**
 * Team attendance in the viewer's scope: a supervisor sees their reporting
 * line, a manager their whole department. Scope is decided by the server.
 */
export default function TeamScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const session = useSession();
  const team = useTeam();
  const [status, setStatus] = useState<StatusFilter>('all');
  const [teamName, setTeamName] = useState<string>('all');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<SortSpec<SortKey>>({ key: 'status', direction: 'asc' });
  const tz = session.data?.organization.timeZone ?? 'UTC';

  const members = useMemo(() => team.data ?? [], [team.data]);
  const teams = useMemo(() => [...new Set(members.map((m) => m.teamName ?? i18n.t('team.noTeam')))].sort(), [members, i18n]);
  const counts = useMemo(() => facetCounts(members, (m) => m.status), [members]);
  const rows = useMemo(
    () =>
      queryList(members, {
        filters: [
          (m) => status === 'all' || m.status === status,
          (m) => teamName === 'all' || (m.teamName ?? i18n.t('team.noTeam')) === teamName,
        ],
        search: { text: search, fields: (m) => [m.person.name, m.person.title, m.teamName, m.managerName] },
        sort,
        locale: i18n.tag,
        accessors: {
          name: (m) => m.person.name,
          status: (m) => STATUS_ORDER.indexOf(m.status),
          today: (m) => m.todayMinutes,
          week: (m) => m.weekMinutes,
          overtime: (m) => m.weekOvertimeMinutes,
          night: (m) => m.weekNightMinutes,
        },
      }),
    [members, status, teamName, search, sort, i18n],
  );

  const statusFilters: FilterOption<StatusFilter>[] = [
    { value: 'all', label: i18n.t('list.all'), count: members.length },
    ...STATUS_ORDER.filter((s) => (counts.get(s) ?? 0) > 0).map((s) => ({ value: s, label: i18n.t(`team.status.${s}`), count: counts.get(s) ?? 0 })),
  ];
  const sortOptions: SortOption<SortKey>[] = [
    { key: 'status', label: i18n.t('team.sort.status') },
    { key: 'name', label: i18n.t('team.sort.name') },
    { key: 'today', label: i18n.t('team.sort.today'), defaultDirection: 'desc' },
    { key: 'week', label: i18n.t('team.sort.week'), defaultDirection: 'desc' },
    { key: 'overtime', label: i18n.t('team.sort.overtime'), defaultDirection: 'desc' },
    { key: 'night', label: i18n.t('team.sort.night'), defaultDirection: 'desc' },
  ];
  const open = (m: TeamMember) => router.push({ pathname: '/more/timesheets', params: { user: m.person.id } });
  const statusPill = (m: TeamMember) => (
    <Pill label={m.lateByMinutes !== undefined && m.status === 'working' ? i18n.t('team.lateBy', { time: formatDuration(m.lateByMinutes) }) : i18n.t(`team.status.${m.status}`)} tone={m.lateByMinutes !== undefined && m.status === 'working' ? 'warning' : STATUS_TONE[m.status]} dot />
  );

  const columns: Column<TeamMember, SortKey>[] = [
    {
      key: 'name',
      title: i18n.t('team.col.person'),
      flex: 2.6,
      sortKey: 'name',
      render: (m) => (
        <View style={styles.person}>
          <Avatar initials={m.person.initials} hue={m.person.hue} size={32} />
          <View style={{ flex: 1 }}>
            <Text variant="subhead" weight="600" numberOfLines={1}>
              {m.person.name}
            </Text>
            <Text variant="caption" color="textSecondary" numberOfLines={1}>
              {m.person.title}
            </Text>
          </View>
        </View>
      ),
    },
    { key: 'team', title: i18n.t('team.col.team'), flex: 1.4, render: (m) => <Text variant="footnote" color="textSecondary" numberOfLines={1}>{m.teamName ?? '—'}</Text> },
    { key: 'status', title: i18n.t('team.col.status'), flex: 1.5, sortKey: 'status', render: statusPill },
    { key: 'in', title: i18n.t('team.col.clockIn'), flex: 1, render: (m) => <Text variant="footnote" tabular>{m.clockIn !== undefined ? i18n.time(m.clockIn, tz) : '—'}</Text> },
    { key: 'today', title: i18n.t('team.col.today'), flex: 1, align: 'right', sortKey: 'today', render: (m) => <Text variant="footnote" tabular>{formatDuration(m.todayMinutes)}</Text> },
    { key: 'week', title: i18n.t('team.col.week'), flex: 1, align: 'right', sortKey: 'week', render: (m) => <Text variant="footnote" tabular weight="600">{formatDuration(m.weekMinutes)}</Text> },
    { key: 'ot', title: i18n.t('team.col.overtime'), flex: 0.9, align: 'right', sortKey: 'overtime', render: (m) => <Text variant="footnote" tabular color={m.weekOvertimeMinutes > 0 ? 'warning' : 'textTertiary'}>{formatDuration(m.weekOvertimeMinutes)}</Text> },
    { key: 'nd', title: i18n.t('team.col.night'), flex: 0.9, align: 'right', sortKey: 'night', render: (m) => <Text variant="footnote" tabular color={m.weekNightMinutes > 0 ? 'info' : 'textTertiary'}>{formatDuration(m.weekNightMinutes)}</Text> },
    { key: 'req', title: i18n.t('team.col.requests'), flex: 0.8, align: 'right', render: (m) => (m.pendingRequests > 0 ? <Pill label={String(m.pendingRequests)} tone="warning" /> : <Text variant="footnote" color="textTertiary">0</Text>) },
  ];

  return (
    <Screen onRefresh={() => team.refetch()} maxWidth={1400}>
      <View style={[styles.summary, { gap: t.space.md }]}>
        {(['working', 'on_break', 'late', 'absent'] as const).map((s) => (
          <Card key={s} style={styles.summaryCell} onPress={() => setStatus(status === s ? 'all' : s)} accessibilityLabel={`${i18n.t(`team.status.${s}`)}: ${counts.get(s) ?? 0}`}>
            <Text variant="title" tabular>
              {counts.get(s) ?? 0}
            </Text>
            <Pill label={i18n.t(`team.status.${s}`)} tone={STATUS_TONE[s]} dot />
          </Card>
        ))}
      </View>
      <ListToolbar
        search={search}
        onSearch={setSearch}
        searchPlaceholder={i18n.t('team.search')}
        filters={statusFilters}
        filter={status}
        onFilter={setStatus}
        sortOptions={sortOptions}
        sort={sort}
        onSort={setSort}
        resultLabel={i18n.plural('list.results', rows.length)}
      />
      {teams.length > 1 && (
        <View style={styles.chips}>
          <Chip label={i18n.t('team.allTeams')} selected={teamName === 'all'} onPress={() => setTeamName('all')} />
          {teams.map((name) => (
            <Chip key={name} label={name} selected={teamName === name} onPress={() => setTeamName(name)} />
          ))}
        </View>
      )}
      {team.isError ? (
        <ErrorState onRetry={() => void team.refetch()} message={errorMessage(team.error, i18n.t('common.errorBody'))} />
      ) : team.data === undefined ? (
        <LoadingBlock rows={5} height={60} />
      ) : rows.length === 0 ? (
        <EmptyState icon="team" title={i18n.t('list.noMatches')} />
      ) : isDesktop ? (
        <DataTable columns={columns} rows={rows} rowKey={(m) => m.person.id} sort={sort} onSort={setSort} onRowPress={open} rowLabel={(m) => `${m.person.name}, ${i18n.t(`team.status.${m.status}`)}`} />
      ) : (
        <ListSection footer={i18n.t('team.scopeFooter')}>
          {rows.map((m, idx) => (
            <Touchable key={m.person.id} onPress={() => open(m)} feedback="highlight" accessibilityLabel={`${m.person.name}, ${i18n.t(`team.status.${m.status}`)}, ${formatDuration(m.weekMinutes)}`}>
              <View style={[styles.mobileRow, { paddingHorizontal: t.space.lg }, idx < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
                <Avatar initials={m.person.initials} hue={m.person.hue} size={40} />
                <View style={{ flex: 1, gap: 4 }}>
                  <Text variant="body" weight="600" numberOfLines={1}>
                    {m.person.name}
                  </Text>
                  <View style={styles.meta}>{statusPill(m)}</View>
                </View>
                <View style={{ alignItems: 'flex-end', gap: 2 }}>
                  <Text variant="subhead" tabular weight="600">
                    {formatDuration(m.weekMinutes)}
                  </Text>
                  <Text variant="caption" color="textSecondary" tabular>
                    {i18n.t('team.otNd', { ot: formatDuration(m.weekOvertimeMinutes), nd: formatDuration(m.weekNightMinutes) })}
                  </Text>
                </View>
              </View>
            </Touchable>
          ))}
        </ListSection>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  summary: { flexDirection: 'row', flexWrap: 'wrap' },
  summaryCell: { flexGrow: 1, flexBasis: '22%', minWidth: 140, gap: 6 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  person: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  mobileRow: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 68, paddingVertical: 10 },
  meta: { flexDirection: 'row', gap: 6 },
});
