import { ROLE_TEMPLATES, type ModuleId } from '@nforce/core';
import Constants from 'expo-constants';
import { router, type Href } from 'expo-router';
import { StyleSheet, View } from 'react-native';

import { Chip, Toggle } from '@/components/Controls';
import { Avatar, Pill } from '@/components/Display';
import type { IconName } from '@/components/Icon';
import { LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { resetSession, useApprovals, useNotifications, useSession } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { LOCALES, useI18n } from '@/i18n';
import { setPreference, usePreference, type Preferences } from '@/state/preferences';

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
  const t = useTheme();
  const i18n = useI18n();
  const { t: tr } = i18n;
  const session = useSession();
  const canApprove = session.data?.modules.includes('approvals') ?? false;
  const approvals = useApprovals(canApprove);
  const notifications = useNotifications();
  const unread = (notifications.data ?? []).filter((n) => !n.read).length;
  const locale = usePreference('locale');
  const haptics = usePreference('haptics');
  const reduceMotion = usePreference('reduceMotion');
  const persona = usePreference('persona');

  const switchPersona = (role: Preferences['persona']) => {
    if (role === persona) return;
    setPreference('persona', role);
    void resetSession();
  };

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
          {session.data.modules.map((m, idx, list) => {
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

      <ListSection title={tr('more.preferences')}>
        <ListRow
          title={tr('customize.title')}
          subtitle={tr('customize.subtitle')}
          icon="palette"
          iconTint="#AF52DE"
          onPress={() => router.push('/more/customize')}
        />
        <Field label={tr('more.language')}>
          <View style={styles.chips}>
            <Chip label={tr('more.language.system')} selected={locale === 'system'} onPress={() => setPreference('locale', 'system')} />
            {LOCALES.map((l) => (
              <Chip key={l.id} label={l.native} selected={locale === l.id} onPress={() => setPreference('locale', l.id)} />
            ))}
          </View>
        </Field>
        <ListRow
          title={tr('more.haptics')}
          icon="hand"
          iconTint="#FF3B30"
          trailing={<Toggle value={haptics} onValueChange={(v) => setPreference('haptics', v)} label={tr('more.haptics')} />}
        />
        <ListRow
          title={tr('more.reduceMotion')}
          icon="motion"
          iconTint="#007AFF"
          trailing={<Toggle value={reduceMotion} onValueChange={(v) => setPreference('reduceMotion', v)} label={tr('more.reduceMotion')} />}
          last
        />
      </ListSection>

      {session.data?.manager !== undefined && (
        <ListSection title={tr('more.reportsTo')}>
          <ListRow
            title={session.data.manager.name}
            subtitle={session.data.manager.title}
            leading={<Avatar initials={session.data.manager.initials} hue={session.data.manager.hue} size={36} />}
            last
          />
        </ListSection>
      )}

      <ListSection title={tr('more.persona')} footer={tr('more.personaFooter')}>
        <View style={[styles.chips, { padding: t.space.lg }]}>
          {ROLE_TEMPLATES.map((r) => (
            <Chip key={r} label={tr(`role.${r}`)} selected={persona === r} onPress={() => switchPersona(r)} />
          ))}
        </View>
      </ListSection>

      <ListSection>
        <ListRow title={tr('more.about')} icon="info" iconTint="#8E8E93" value={tr('more.version', { version: Constants.expoConfig?.version ?? '0.1.0' })} />
        <ListRow title={tr('more.privacy')} icon="shield" iconTint="#34C759" last />
      </ListSection>
    </Screen>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  const t = useTheme();
  return (
    <View
      style={{
        padding: t.space.lg,
        gap: t.space.sm,
        borderBottomWidth: t.flavor === 'ios' ? StyleSheet.hairlineWidth : 0,
        borderBottomColor: t.colors.separator,
      }}
    >
      <Text variant="subhead" color="textSecondary">
        {label}
      </Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  profile: { flexDirection: 'row', alignItems: 'center', gap: 16 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
