import type { ModuleId } from '@nforce/core';
import { router, usePathname, type Href } from 'expo-router';
import { Image, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useApprovals, useAttendance, useSession } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useI18n, type MessageKey } from '@/i18n';
import { setPreference, usePreference } from '@/state/preferences';
import { Avatar } from './Display';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

interface NavItem {
  readonly href: Href;
  readonly match: string;
  readonly label: MessageKey;
  readonly icon: IconName;
  readonly badge?: number;
}

const MODULE_NAV: Partial<Record<ModuleId, Omit<NavItem, 'badge'>>> = {
  team: { href: '/more/team', match: '/more/team', label: 'module.team', icon: 'team' },
  approvals: { href: '/more/approvals', match: '/more/approvals', label: 'module.approvals', icon: 'approvals' },
  timesheets: { href: '/more/timesheets', match: '/more/timesheets', label: 'module.timesheets', icon: 'timesheets' },
  timeoff: { href: '/more/timeoff', match: '/more/timeoff', label: 'module.timeoff', icon: 'timeoff' },
  people: { href: '/more/module/people', match: '/more/module/people', label: 'module.people', icon: 'people' },
  payroll: { href: '/more/module/payroll', match: '/more/module/payroll', label: 'module.payroll', icon: 'payroll' },
  reports: { href: '/more/module/reports', match: '/more/module/reports', label: 'module.reports', icon: 'reports' },
  admin: { href: '/more/module/admin', match: '/more/module/admin', label: 'module.admin', icon: 'admin' },
};

/**
 * Desktop / large-screen navigation (web and Android tablets). Expanded
 * sidebar or icon-only rail, chosen by the user in Customize.
 */
export function Sidebar() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const insets = useSafeAreaInsets();
  const pathname = usePathname();
  const mode = usePreference('sidebar');
  const rail = mode === 'rail';
  const session = useSession();
  const canApprove = session.data?.modules.includes('approvals') ?? false;
  const approvals = useApprovals(canApprove);
  const attendance = useAttendance();
  const pending = (approvals.data ?? []).filter((a) => a.canDecide).length;

  const main: NavItem[] = [
    { href: '/home', match: '/home', label: 'tabs.home', icon: 'home' },
    { href: '/work', match: '/work', label: 'tabs.work', icon: 'work' },
    { href: '/clock', match: '/clock', label: 'tabs.clock', icon: 'clock' },
    { href: '/schedule', match: '/schedule', label: 'tabs.schedule', icon: 'schedule' },
  ];
  const modules: NavItem[] = (session.data?.modules ?? []).flatMap((m) => {
    const item = MODULE_NAV[m];
    return item === undefined ? [] : [{ ...item, ...(m === 'approvals' && pending > 0 ? { badge: pending } : {}) }];
  });
  const footer: NavItem[] = [
    { href: '/more/customize', match: '/more/customize', label: 'customize.title', icon: 'palette' },
    { href: '/more', match: '/more', label: 'tabs.more', icon: 'settings' },
  ];
  const isActive = (item: NavItem) => (item.match === '/more' ? pathname === '/more' : pathname.startsWith(item.match));
  const status = attendance.data?.status ?? 'off';
  const statusColor = status === 'working' ? t.colors.success : status === 'on_break' ? t.colors.warning : t.colors.textTertiary;

  const renderItem = (item: NavItem) => {
    const active = isActive(item);
    const label = tr(item.label);
    return (
      <Touchable
        key={item.match}
        onPress={() => router.navigate(item.href)}
        feedback="highlight"
        accessibilityRole="link"
        accessibilityState={{ selected: active }}
        accessibilityLabel={item.badge !== undefined ? `${label}, ${item.badge}` : label}
        style={[
          styles.item,
          rail && styles.itemRail,
          { borderRadius: t.flavor === 'ios' ? 10 : 999 },
          active && { backgroundColor: t.flavor === 'ios' ? t.colors.primaryContainer : t.colors.tonal },
        ]}
      >
        <Icon name={item.icon} size={20} color={active ? (t.flavor === 'ios' ? t.colors.primary : t.colors.onTonal) : t.colors.textSecondary} weight={active ? 'semibold' : 'regular'} />
        {!rail && (
          <Text variant="subhead" weight={active ? '600' : '500'} style={{ flex: 1, color: active ? (t.flavor === 'ios' ? t.colors.primary : t.colors.onTonal) : t.colors.text }} numberOfLines={1}>
            {label}
          </Text>
        )}
        {item.badge !== undefined && (
          <View style={[styles.badge, rail && styles.badgeRail, { backgroundColor: t.colors.danger }]}>
            <Text variant="caption" weight="700" style={{ color: '#FFFFFF', fontSize: 11, lineHeight: 14 }}>
              {item.badge}
            </Text>
          </View>
        )}
      </Touchable>
    );
  };

  return (
    <View
      accessibilityRole="menu"
      style={[
        styles.root,
        { width: rail ? 80 : 264, backgroundColor: t.flavor === 'ios' ? t.colors.surface : t.colors.background, borderRightColor: t.colors.separator, paddingTop: insets.top + 12, paddingBottom: insets.bottom + 12 },
      ]}
    >
      <View style={[styles.brand, rail && { justifyContent: 'center' }]}>
        <Image source={require('../../assets/brand/logo.png')} style={styles.logo} resizeMode="contain" accessibilityLabel="NForce" />
        {!rail && (
          <View style={{ flex: 1 }}>
            <Text variant="headline" weight="700">
              NForce
            </Text>
            <Text variant="caption" color="textSecondary" numberOfLines={1}>
              {session.data?.organization.name ?? ''}
            </Text>
          </View>
        )}
        <Touchable
          onPress={() => setPreference('sidebar', rail ? 'expanded' : 'rail')}
          feedback="highlight"
          accessibilityLabel={tr(rail ? 'customize.sidebar.expanded' : 'customize.sidebar.rail')}
          style={[styles.collapse, rail && { position: 'absolute', right: -14, top: 42, backgroundColor: t.colors.surfaceRaised, borderColor: t.colors.separator, borderWidth: 1 }]}
        >
          <Icon name="sidebar" size={16} color={t.colors.textSecondary} />
        </Touchable>
      </View>

      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ gap: 2, paddingHorizontal: 12 }}>
        {main.map(renderItem)}
        {modules.length > 0 && (
          <Text variant="caption" weight="700" color="textTertiary" style={[styles.section, rail && { textAlign: 'center' }]}>
            {rail ? '•••' : tr('more.workspace').toUpperCase()}
          </Text>
        )}
        {modules.map(renderItem)}
      </ScrollView>

      <View style={{ gap: 2, paddingHorizontal: 12 }}>{footer.map(renderItem)}</View>

      {session.data !== undefined && (
        <Touchable
          onPress={() => router.navigate('/clock')}
          feedback="highlight"
          accessibilityLabel={`${session.data.user.name}, ${tr(`clock.${status}`)}`}
          style={[styles.user, rail && { justifyContent: 'center' }, { borderTopColor: t.colors.separator }]}
        >
          <View>
            <Avatar initials={session.data.user.initials} hue={session.data.user.hue} size={36} />
            <View style={[styles.presence, { backgroundColor: statusColor, borderColor: t.colors.surface }]} />
          </View>
          {!rail && (
            <View style={{ flex: 1 }}>
              <Text variant="subhead" weight="600" numberOfLines={1}>
                {session.data.user.name}
              </Text>
              <Text variant="caption" color="textSecondary" numberOfLines={1}>
                {tr(`role.${session.data.role}`)} · {tr(`clock.${status}`)}
              </Text>
            </View>
          )}
        </Touchable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { borderRightWidth: StyleSheet.hairlineWidth, gap: 8 },
  brand: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 16, paddingBottom: 12 },
  logo: { width: 36, height: 36 },
  collapse: { width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  section: { paddingHorizontal: 12, paddingTop: 16, paddingBottom: 6, letterSpacing: 0.6 },
  item: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 40, paddingHorizontal: 12 },
  itemRail: { justifyContent: 'center', paddingHorizontal: 0, minHeight: 44 },
  badge: { minWidth: 20, height: 20, borderRadius: 10, paddingHorizontal: 6, alignItems: 'center', justifyContent: 'center' },
  badgeRail: { position: 'absolute', top: 2, right: 6 },
  user: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 16, paddingTop: 12, borderTopWidth: StyleSheet.hairlineWidth },
  presence: { position: 'absolute', right: -1, bottom: -1, width: 12, height: 12, borderRadius: 6, borderWidth: 2 },
});
