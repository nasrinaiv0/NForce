import { router, type Href } from 'expo-router';
import { StyleSheet, View } from 'react-native';

import { useMemo } from 'react';

import { Button } from '@/components/Button';
import { Icon, type IconName } from '@/components/Icon';
import { ListControls, useListView } from '@/components/ListView';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { notificationFields } from '@/data/listFields';
import { errorMessage, useMarkNotificationsRead, useNotifications, useSession } from '@/data/queries';
import type { NotificationItem } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useI18n, type I18n } from '@/i18n';

const KIND_ICON: Readonly<Record<NotificationItem['kind'], IconName>> = {
  approval_needed: 'approvals',
  request_decided: 'checkCircle',
  timesheet_due: 'timesheets',
  missed_punch: 'warning',
  payroll_ready: 'payroll',
};

function message(n: NotificationItem, i18n: I18n, tz: string): string {
  const p = n.params;
  switch (n.kind) {
    case 'approval_needed':
      return i18n.plural('notify.approvals', Number(p['count'] ?? 0));
    case 'request_decided':
      return i18n.t(p['status'] === 'approved' ? 'notify.approved' : 'notify.returned', { kind: i18n.t(`approvals.kind.${(p['kind'] ?? 'leave') as 'leave'}`), name: p['by'] ?? '' });
    case 'timesheet_due':
      return i18n.t('notify.timesheetDue', { period: i18n.date((p['period'] ?? '2026-01-01') as never, { month: 'short', day: 'numeric' }) });
    case 'missed_punch':
      return i18n.t('notify.missedPunch', { time: i18n.time(p['at'] ?? new Date().toISOString(), tz) });
    case 'payroll_ready':
      return Number(p['blockers'] ?? 0) === 0 ? i18n.t('notify.payrollReady') : i18n.plural('notify.payrollBlocked', Number(p['blockers'] ?? 0));
  }
}

/** In-app inbox. Previews never include salary, medical or other confidential data. */
export default function NotificationsScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const now = useNow(60_000);
  const session = useSession();
  const notifications = useNotifications();
  const markRead = useMarkNotificationsRead();
  const all = notifications.data ?? [];
  const unread = all.filter((n) => !n.read);
  const tz = session.data?.organization.timeZone ?? 'UTC';
  const list = useListView({
    id: 'notifications',
    fields: useMemo(() => notificationFields(i18n), [i18n]),
    defaultSort: { key: 'date', direction: 'desc' },
    searchText: (n) => [message(n, i18n, tz)],
    quickFilters: [
      { value: 'all', label: i18n.t('list.all') },
      { value: 'unread', label: i18n.t('notify.unread'), test: (n: NotificationItem) => !n.read },
    ],
  });
  const items = list.apply(all);

  return (
    <Screen onRefresh={() => notifications.refetch()} maxWidth={800}>
      {notifications.isError ? (
        <ErrorState onRetry={() => void notifications.refetch()} message={errorMessage(notifications.error, i18n.t('common.errorBody'))} />
      ) : notifications.data === undefined ? (
        <LoadingBlock rows={3} height={64} />
      ) : all.length === 0 ? (
        <EmptyState icon="bell" title={i18n.t('notify.emptyTitle')} body={i18n.t('notify.emptyBody')} />
      ) : (
        <>
          <ListControls state={list} searchPlaceholder={i18n.t('list.search')} resultCount={items.length} quickCounts={{ all: all.length, unread: unread.length }} />
          {items.length === 0 && <EmptyState icon="search" title={i18n.t('list.noMatches')} />}
          {unread.length > 0 && <Button title={i18n.t('notify.markAll')} variant="plain" size="small" onPress={() => markRead.mutate(unread.map((n) => n.id))} style={{ alignSelf: 'flex-end' }} />}
          {items.length > 0 && (
          <ListSection>
            {items.map((n, idx) => (
              <Touchable
                key={n.id}
                feedback="highlight"
                accessibilityLabel={`${n.read ? '' : `${i18n.t('notify.unread')}, `}${message(n, i18n, tz)}`}
                onPress={() => {
                  markRead.mutate([n.id]);
                  if (n.href !== undefined) router.push(n.href as Href);
                }}
              >
                <View style={[styles.row, { paddingHorizontal: t.space.lg }, idx < items.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
                  <View style={[styles.icon, { backgroundColor: t.colors.primaryContainer }]}>
                    <Icon name={KIND_ICON[n.kind]} size={18} color={t.colors.onPrimaryContainer} />
                  </View>
                  <View style={{ flex: 1, gap: 2 }}>
                    <Text variant="subhead" weight={n.read ? '400' : '600'}>
                      {message(n, i18n, tz)}
                    </Text>
                    <Text variant="caption" color="textTertiary">
                      {i18n.relative(n.at, now)}
                    </Text>
                  </View>
                  {!n.read && <View style={[styles.dot, { backgroundColor: t.colors.primary }]} />}
                </View>
              </Touchable>
            ))}
          </ListSection>
          )}
        </>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 64, paddingVertical: 10 },
  icon: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
  dot: { width: 10, height: 10, borderRadius: 5 },
});
