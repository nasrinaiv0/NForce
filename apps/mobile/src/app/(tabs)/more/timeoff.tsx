import { router } from 'expo-router';
import { View } from 'react-native';

import { Button } from '@/components/Button';
import { Meter, Pill, type Tone } from '@/components/Display';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { LEAVE_TYPES } from '@/data/mockApi';
import { keys, queryClient, useBalances, useTimeOffRequests } from '@/data/queries';
import type { RequestStatus } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<RequestStatus, Tone>> = {
  pending: 'warning',
  approved: 'success',
  rejected: 'danger',
  cancelled: 'neutral',
};

export default function TimeOffScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const balances = useBalances();
  const requests = useTimeOffRequests();

  const refresh = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: keys.balances() }),
      queryClient.invalidateQueries({ queryKey: keys.timeOff() }),
    ]);

  return (
    <Screen onRefresh={refresh}>
      <Button title={i18n.t('timeoff.new')} icon="add" onPress={() => router.push('/request-time-off')} />

      <View style={{ gap: t.space.md }}>
        <Text variant="footnote" color="textSecondary" style={{ paddingHorizontal: t.space.lg, textTransform: t.flavor === 'ios' ? 'uppercase' : 'none' }}>
          {i18n.t('timeoff.balances')}
        </Text>
        {balances.isError ? (
          <ErrorState onRetry={() => void balances.refetch()} />
        ) : balances.data === undefined ? (
          <LoadingBlock rows={3} height={64} />
        ) : (
          balances.data.map((b) => (
            <Card key={b.leaveTypeId} style={{ gap: t.space.sm }}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <Text variant="headline">{b.name}</Text>
                <Text variant="subhead" color="textSecondary" tabular>
                  {i18n.t('timeoff.of', { available: i18n.number(b.available), entitled: i18n.number(b.entitled) })}
                </Text>
              </View>
              <Meter value={b.available / b.entitled} color={`hsl(${b.hue}, 70%, ${t.scheme === 'dark' ? 65 : 48}%)`} height={8} />
            </Card>
          ))
        )}
      </View>

      <ListSection title={i18n.t('timeoff.requests')}>
        {requests.data === undefined ? (
          <View style={{ padding: t.space.lg }}>
            <LoadingBlock rows={2} height={20} />
          </View>
        ) : requests.data.length === 0 ? (
          <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
            {i18n.t('timeoff.empty')}
          </Text>
        ) : (
          requests.data.map((r, idx) => {
            const type = r.kind === 'day_off' ? i18n.t('timeoff.kind.day_off') : (LEAVE_TYPES.find((l) => l.id === r.leaveTypeId)?.name ?? i18n.t('timeoff.kind.leave'));
            const dates = r.start === r.end ? i18n.date(r.start) : `${i18n.date(r.start)} – ${i18n.date(r.end)}`;
            return (
              <ListRow
                key={r.id}
                title={type}
                subtitle={`${dates} · ${i18n.plural('timeoff.days', r.days)}`}
                trailing={<Pill label={i18n.t(`timeoff.status.${r.status}`)} tone={STATUS_TONE[r.status]} />}
                last={idx === requests.data.length - 1}
              />
            );
          })
        )}
      </ListSection>
    </Screen>
  );
}
