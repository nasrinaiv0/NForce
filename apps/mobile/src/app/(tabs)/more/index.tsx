import { type ModuleId } from '@nforce/core';
import { router, type Href } from 'expo-router';
import { StyleSheet, View } from 'react-native';

import { Avatar, Pill } from '@/components/Display';
import type { IconName } from '@/components/Icon';
import { LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { useApprovals, useNotifications, useSession } from '@/data/queries';
import { useI18n } from '@/i18n';
import { personalNavigation } from '@/data/personalNavigation';

const MODULE_META: Readonly<Record<ModuleId, { icon: IconName; tint: string; href: Href }>> = {
  attendance: { icon: 'attendance', tint: '#30B0C7', href: '/more/attendance' },
  team: { icon: 'team', tint: '#0A84FF', href: '/more/team' },
  approvals: { icon: 'approvals', tint: '#FF9500', href: '/more/approvals' },
  timesheets: { icon: 'timesheets', tint: '#5856D6', href: '/more/timesheets' },
  timeoff: { icon: 'timeoff', tint: '#34C759', href: '/more/timeoff' },
  people: { icon: 'people', tint: '#007AFF', href: '/more/people' },
  payroll: { icon: 'payroll', tint: '#30B0C7', href: '/more/payroll' },
  crm: { icon: 'crm', tint: '#AF52DE', href: '/more/crm' },
  reports: { icon: 'reports', tint: '#FF2D55', href: '/more/reports' },
  admin: { icon: 'admin', tint: '#8E8E93', href: '/more/admin' },
};

export default function MoreScreen() {
  const i18n = useI18n();
  const { t: tr } = i18n;
  const session = useSession();
  const canApprove = session.data?.modules.includes('approvals') ?? false;
  const approvals = useApprovals(canApprove);
  const notifications = useNotifications();
  const unread = (notifications.data ?? []).filter((n) => !n.read).length;
  const labels = personalNavigation[i18n.locale];

  return (
    <Screen>
      {session.data === undefined ? (
        <LoadingBlock rows={1} height={88} />
      ) : (
        <Card style={styles.profile}>
          <Avatar initials={session.data.user.initials} hue={session.data.user.hue} size={60} />
          <View style={{ flex: 1, gap: 2 }}>
            <Text variant="title2">{session.data.user.name}</Text>
            <Text variant="subhead" color="textSecondary" numberOfLines={1}>
              {session.data.user.title}
            </Text>
            <View style={[styles.row, { marginTop: 6 }]}>
              <Pill label={tr(`role.${session.data.role}`)} tone="primary" icon="shield" />
              <Text variant="footnote" color="textTertiary" numberOfLines={1} style={{ flex: 1 }}>
                {session.data.organization.name}
              </Text>
            </View>
          </View>
        </Card>
      )}

      <ListSection>
        <ListRow title={labels.profile} icon="person" iconTint="#007AFF" onPress={()=>router.push('/more/my-profile' as Href)} />
        <ListRow title={labels.settings} icon="settings" iconTint="#8E8E93" onPress={()=>router.push('/more/settings' as Href)} last />
      </ListSection>

      <ListSection>
        <ListRow
          title={tr('notify.title')}
          icon="bell"
          iconTint="#FF3B30"
          onPress={() => router.push('/more/notifications')}
          trailing={unread > 0 ? <Pill label={String(unread)} tone="danger" /> : undefined}
          last
        />
      </ListSection>

      {session.data !== undefined && (
        <ListSection title={tr('more.workspace')}>
          {[...session.data.modules.filter(m => m !== 'payroll'), 'payroll' as const].map((m, idx, list) => {
            const meta = MODULE_META[m];
            const count = m === 'approvals' ? (approvals.data ?? []).filter((a) => a.canDecide).length : 0;
            return (
              <ListRow
                key={m}
                title={tr(`module.${m}`)}
                icon={meta.icon}
                iconTint={meta.tint}
                onPress={() => router.push(meta.href)}
                trailing={count > 0 ? <Pill label={String(count)} tone="danger" /> : undefined}
                last={idx === list.length - 1}
              />
            );
          })}
        </ListSection>
      )}

    </Screen>
  );
}

const styles=StyleSheet.create({profile:{flexDirection:'row',alignItems:'center',gap:16},row:{flexDirection:'row',alignItems:'center',gap:8}});
