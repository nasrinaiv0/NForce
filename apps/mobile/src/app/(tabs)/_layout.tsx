import type { AndroidSymbol } from 'expo-symbols';
import { NativeTabs } from 'expo-router/native-tabs';
import { Tabs } from 'expo-router/tabs';
import { Platform, View } from 'react-native';
import type { SFSymbol } from 'sf-symbols-typescript';

import { Icon, type IconName } from '@/components/Icon';
import { useApprovals, useSession } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useI18n, type MessageKey } from '@/i18n';

interface TabSpec {
  readonly name: 'home' | 'work' | 'clock' | 'schedule' | 'more';
  readonly label: MessageKey;
  readonly icon: IconName;
  readonly sf: { default: SFSymbol; selected: SFSymbol };
  readonly md: AndroidSymbol;
}

const TABS: readonly TabSpec[] = [
  { name: 'home', label: 'tabs.home', icon: 'home', sf: { default: 'house', selected: 'house.fill' }, md: 'home' },
  { name: 'work', label: 'tabs.work', icon: 'work', sf: { default: 'checklist', selected: 'checklist.checked' }, md: 'task_alt' },
  { name: 'clock', label: 'tabs.clock', icon: 'clock', sf: { default: 'clock', selected: 'clock.fill' }, md: 'schedule' },
  { name: 'schedule', label: 'tabs.schedule', icon: 'schedule', sf: { default: 'calendar', selected: 'calendar' }, md: 'calendar_month' },
  { name: 'more', label: 'tabs.more', icon: 'more', sf: { default: 'square.grid.2x2', selected: 'square.grid.2x2.fill' }, md: 'apps' },
];

/** Pending approvals badge, only for members who can approve. */
function usePendingApprovals(): number {
  const session = useSession();
  const canApprove = session.data?.modules.includes('approvals') ?? false;
  const approvals = useApprovals(canApprove);
  return canApprove ? (approvals.data?.length ?? 0) : 0;
}

/**
 * Native tab bar on device: UITabBar (Liquid Glass on iOS 26+) and the
 * Material 3 NavigationBar on Android, with SF Symbols / Material Symbols.
 * The web preview uses a JS bottom bar styled to the active flavor.
 */
export default function TabsLayout() {
  return Platform.OS === 'web' ? <WebTabs /> : <DeviceTabs />;
}

function DeviceTabs() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const pending = usePendingApprovals();
  return (
    <NativeTabs
      tintColor={t.colors.primary}
      backgroundColor={t.flavor === 'android' ? t.colors.surface : undefined}
      badgeBackgroundColor={t.colors.danger}
      minimizeBehavior="onScrollDown"
    >
      {TABS.map((tab) => (
        <NativeTabs.Trigger key={tab.name} name={tab.name}>
          <NativeTabs.Trigger.Icon sf={tab.sf} md={tab.md} />
          <NativeTabs.Trigger.Label>{tr(tab.label)}</NativeTabs.Trigger.Label>
          {tab.name === 'more' && pending > 0 && <NativeTabs.Trigger.Badge>{String(pending)}</NativeTabs.Trigger.Badge>}
        </NativeTabs.Trigger>
      ))}
    </NativeTabs>
  );
}

function WebTabs() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const pending = usePendingApprovals();
  const android = t.flavor === 'android';
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: android ? t.colors.text : t.colors.primary,
        tabBarInactiveTintColor: t.colors.textSecondary,
        tabBarStyle: {
          backgroundColor: android ? t.colors.surface : t.colors.surfaceRaised,
          borderTopColor: t.colors.separator,
          borderTopWidth: android ? 0 : 0.5,
          height: android ? 80 : 64,
          paddingTop: android ? 12 : 6,
        },
        tabBarLabelStyle: { fontSize: android ? 12 : 10, fontWeight: android ? '600' : '500', marginTop: android ? 4 : 0 },
        tabBarBadgeStyle: { backgroundColor: t.colors.danger },
      }}
    >
      {TABS.map((tab) => (
        <Tabs.Screen
          key={tab.name}
          name={tab.name}
          options={{
            title: tr(tab.label),
            tabBarBadge: tab.name === 'more' && pending > 0 ? pending : undefined,
            tabBarIcon: ({ color, focused }) =>
              android ? (
                <View
                  style={{
                    width: 64,
                    height: 32,
                    borderRadius: 16,
                    alignItems: 'center',
                    justifyContent: 'center',
                    backgroundColor: focused ? t.colors.primaryContainer : 'transparent',
                  }}
                >
                  <Icon name={tab.icon} size={24} color={focused ? t.colors.onPrimaryContainer : color} />
                </View>
              ) : (
                <Icon name={tab.icon} size={24} color={color} weight={focused ? 'semibold' : 'regular'} />
              ),
          }}
        />
      ))}
    </Tabs>
  );
}
