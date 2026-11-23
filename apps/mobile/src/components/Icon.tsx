import type { AndroidSymbol } from 'expo-symbols';
import { SymbolView } from 'expo-symbols';
import { memo } from 'react';
import { View, type ColorValue } from 'react-native';
import type { SFSymbol } from 'sf-symbols-typescript';

import { useTheme } from '@/design/theme';

/**
 * Platform-native iconography: SF Symbols on iOS, Material Symbols on Android
 * (and on web). Every icon in the app is declared once in `ICONS`, so the two
 * platforms can never drift apart.
 */
export const ICONS = {
  home: { ios: 'house', android: 'home' },
  work: { ios: 'checklist', android: 'task_alt' },
  clock: { ios: 'clock', android: 'schedule' },
  schedule: { ios: 'calendar', android: 'calendar_month' },
  more: { ios: 'square.grid.2x2', android: 'apps' },
  add: { ios: 'plus', android: 'add' },
  chevron: { ios: 'chevron.right', android: 'chevron_right' },
  check: { ios: 'checkmark', android: 'check' },
  checkCircle: { ios: 'checkmark.circle.fill', android: 'check_circle' },
  circle: { ios: 'circle', android: 'radio_button_unchecked' },
  approvals: { ios: 'checkmark.seal', android: 'fact_check' },
  timesheets: { ios: 'list.bullet.clipboard', android: 'pending_actions' },
  timeoff: { ios: 'beach.umbrella', android: 'beach_access' },
  people: { ios: 'person.2', android: 'groups' },
  payroll: { ios: 'banknote', android: 'payments' },
  crm: { ios: 'briefcase', android: 'work' },
  reports: { ios: 'chart.bar', android: 'bar_chart' },
  admin: { ios: 'gearshape.2', android: 'admin_panel_settings' },
  location: { ios: 'mappin.and.ellipse', android: 'location_on' },
  coffee: { ios: 'cup.and.saucer', android: 'coffee' },
  play: { ios: 'play.fill', android: 'play_arrow' },
  stop: { ios: 'stop.fill', android: 'stop' },
  login: { ios: 'arrow.right.circle', android: 'login' },
  logout: { ios: 'arrow.left.circle', android: 'logout' },
  warning: { ios: 'exclamationmark.triangle', android: 'warning' },
  bell: { ios: 'bell', android: 'notifications' },
  globe: { ios: 'globe', android: 'language' },
  moon: { ios: 'moon', android: 'dark_mode' },
  hand: { ios: 'hand.tap', android: 'vibration' },
  motion: { ios: 'figure.walk.motion', android: 'animation' },
  phone: { ios: 'iphone', android: 'smartphone' },
  person: { ios: 'person.crop.circle', android: 'account_circle' },
  info: { ios: 'info.circle', android: 'info' },
  calendarCheck: { ios: 'calendar.badge.checkmark', android: 'event_available' },
  trend: { ios: 'chart.line.uptrend.xyaxis', android: 'trending_up' },
  flag: { ios: 'flag.fill', android: 'flag' },
  sparkles: { ios: 'sparkles', android: 'auto_awesome' },
  shield: { ios: 'lock.shield', android: 'shield_lock' },
  close: { ios: 'xmark', android: 'close' },
  link: { ios: 'link', android: 'link' },
} as const satisfies Record<string, { ios: SFSymbol; android: AndroidSymbol }>;

export type IconName = keyof typeof ICONS;

export interface IconProps {
  name: IconName;
  size?: number;
  color?: ColorValue;
  weight?: 'regular' | 'medium' | 'semibold' | 'bold';
}

export const Icon = memo(function Icon({ name, size = 22, color, weight = 'regular' }: IconProps) {
  const t = useTheme();
  const glyph = ICONS[name];
  return (
    <SymbolView
      name={{ ios: glyph.ios, android: glyph.android, web: glyph.android }}
      size={size}
      tintColor={color ?? t.colors.text}
      weight={weight}
      resizeMode="scaleAspectFit"
      fallback={<View style={{ width: size, height: size }} />}
      accessible={false}
      importantForAccessibility="no"
    />
  );
});
