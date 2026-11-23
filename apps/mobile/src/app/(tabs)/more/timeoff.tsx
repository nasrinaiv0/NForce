import { formatDuration, queryList, type ApprovalStatus, type SortSpec } from '@nforce/core';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { ApproverChain } from '@/components/ApproverChain';
import { Button } from '@/components/Button';
import { Meter, Pill, type Tone } from '@/components/Display';
import { FilterChips, SortButton } from '@/components/ListToolbar';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, keys, queryClient, useApproverPreview, useBalances, useMyRequests } from '@/data/queries';
import type { MyRequest } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<ApprovalStatus, Tone>> = { pending: 'warning', approved: 'success', returned: 'danger', cancelled: 'neutral' };
type StatusFilter = 'all' | ApprovalStatus;
type SortKey = 'submitted' | 'starts';

function requestTitle(r: MyRequest, i18n: I18n): { title: string; subtitle: string; start: string } {
  const p = r.payload;
  switch (p.kind) {
    case 'leave':
    case 'day_off': {
      const dates = p.start === p.end ? i18n.date(p.start) : `${i18n.date(p.start)} – ${i18n.date(p.end)}`;
      return { title: p.kind === 'leave' ? p.leaveType : i18n.t('timeoff.kind.day_off'), subtitle: `${dates} · ${i18n.plural('timeoff.days', p.days)}`, start: p.start };
    }
    case 'overtime':
      return { title: i18n.t('approvals.kind.overtime'), subtitle: `${i18n.date(p.date)} · ${formatDuration(p.minutes)}`, start: p.date };
    case 'timesheet':
      return { title: i18n.t('approvals.kind.timesheet'), subtitle: i18n.t('approvals.weekOf', { date: i18n.date(p.periodStart) }), start: p.periodStart };
    case 'correction':
      return { title: i18n.t('approvals.kind.correction'), subtitle: i18n.date(p.date), start: p.date };
  }
}

export default function TimeOffScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { isDesktop } = useResponsive();
  const balances = useBalances();
  const requests = useMyRequests();
  const chain = useApproverPreview();
  const [status, setStatus] = useState<StatusFilter>('all');
  const [sort, setSort] = useState<SortSpec<SortKey>>({ key: 'submitted', direction: 'desc' });

  const rows = useMemo(
    () =>
      queryList(requests.data ?? [], {
        filters: status === 'all' ? [] : [(r) => r.status === status],
        sort,
        accessors: { submitted: (r) => r.submittedAt, starts: (r) => requestTitle(r, i18n).start },
      }),
    [requests.data, status, sort, i18n],
  );
  const count = (s: ApprovalStatus) => (requests.data ?? []).filter((r) => r.status === s).length;
  const refresh = () => Promise.all([queryClient.invalidateQueries({ queryKey: keys.balances() }), queryClient.invalidateQueries({ queryKey: keys.requests() })]);

  const balancesBlock = (
    <View style={{ gap: t.space.md }}>
      <Button title={i18n.t('timeoff.new')} icon="add" onPress={() => router.push('/request-time-off')} />
      {chain.data !== undefined && (
        <Card style={{ gap: t.space.sm }}>
          <Text variant="footnote" color="textSecondary" weight="600">
            {i18n.t('approvals.routeTo')}
          </Text>
          <ApproverChain steps={chain.data} i18n={i18n} />
        </Card>
      )}
      {chain.isError && (
        <Card style={{ backgroundColor: t.colors.fill }}>
          <Text variant="footnote" color="textSecondary" accessibilityRole="alert">
            {errorMessage(chain.error, i18n.t('common.errorBody'))}
          </Text>
        </Card>
      )}
      {balances.isError ? (
        <ErrorState onRetry={() => void balances.refetch()} />
      ) : balances.data === undefined ? (
        <LoadingBlock rows={3} height={64} />
      ) : (
        balances.data.map((b) => (
          <Card key={b.leaveTypeId} style={{ gap: t.space.sm }}>
            <View style={styles.rowBetween}>
              <Text variant="headline">{b.name}</Text>
              <Text variant="subhead" color="textSecondary" tabular>
                {i18n.t('timeoff.of', { available: i18n.number(b.available), entitled: i18n.number(b.entitled) })}
              </Text>
            </View>
            <Meter value={b.available / b.entitled} color={`hsl(${b.hue}, 70%, ${t.scheme === 'dark' ? 65 : 45}%)`} height={8} />
          </Card>
        ))
      )}
    </View>
  );

  const requestsBlock = (
    <View style={{ gap: t.space.md }}>
      <View style={styles.rowBetween}>
        <Text variant={t.flavor === 'ios' ? 'title2' : 'headline'} accessibilityRole="header">
          {i18n.t('timeoff.myRequests')}
        </Text>
        <SortButton
          options={[
            { key: 'submitted', label: i18n.t('approvals.sort.submitted'), defaultDirection: 'desc' },
            { key: 'starts', label: i18n.t('approvals.sort.starts') },
          ]}
          value={sort}
          onChange={setSort}
        />
      </View>
      <FilterChips
        options={[
          { value: 'all', label: i18n.t('list.all'), count: requests.data?.length ?? 0 },
          { value: 'pending', label: i18n.t('approvals.status.pending'), count: count('pending') },
          { value: 'approved', label: i18n.t('approvals.status.approved'), count: count('approved') },
          { value: 'returned', label: i18n.t('approvals.status.returned'), count: count('returned') },
        ]}
        value={status}
        onChange={setStatus}
      />
      <ListSection>
        {requests.data === undefined ? (
          <View style={{ padding: t.space.lg }}>
            <LoadingBlock rows={2} height={20} />
          </View>
        ) : rows.length === 0 ? (
          <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
            {i18n.t('timeoff.empty')}
          </Text>
        ) : (
          rows.map((r, idx) => {
            const { title, subtitle } = requestTitle(r, i18n);
            const current = r.steps.find((s) => s.status === 'pending');
            const returned = r.steps.find((s) => s.status === 'returned');
            return (
              <View key={r.id} style={[styles.reqRow, { paddingHorizontal: t.space.lg }, idx < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
                <View style={{ flex: 1, gap: 2 }}>
                  <Text variant="body" weight="600">
                    {title}
                  </Text>
                  <Text variant="footnote" color="textSecondary">
                    {subtitle}
                  </Text>
                  {current !== undefined && (
                    <Text variant="caption" color="textTertiary">
                      {i18n.t('timeoff.waitingOn', { name: current.approver.name, level: i18n.t(`approvals.level.${current.level}`) })}
                    </Text>
                  )}
                  {returned?.reason !== undefined && (
                    <Text variant="caption" color="danger">
                      “{returned.reason}” — {returned.approver.name}
                    </Text>
                  )}
                </View>
                <Pill label={i18n.t(`approvals.status.${r.status}`)} tone={STATUS_TONE[r.status]} />
              </View>
            );
          })
        )}
      </ListSection>
    </View>
  );

  return (
    <Screen onRefresh={refresh} maxWidth={1100}>
      {isDesktop ? (
        <View style={[styles.columns, { gap: t.space.xxl }]}>
          <View style={{ flex: 1 }}>{balancesBlock}</View>
          <View style={{ flex: 1.3 }}>{requestsBlock}</View>
        </View>
      ) : (
        <>
          {balancesBlock}
          {requestsBlock}
        </>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  columns: { flexDirection: 'row', alignItems: 'flex-start' },
  reqRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12 },
});
