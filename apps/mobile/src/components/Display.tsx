import { memo, useEffect, useState } from 'react';
import { Animated, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import Svg, { Circle, Defs, LinearGradient, Stop } from 'react-native-svg';

import { useTheme } from '@/design/theme';
import type { Palette } from '@/design/tokens';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';

/** Initials avatar with a deterministic, accessible hue. */
export const Avatar = memo(function Avatar({ initials, hue, size = 40 }: { initials: string; hue: number; size?: number }) {
  const t = useTheme();
  const dark = t.scheme === 'dark';
  return (
    <View
      accessible={false}
      style={{
        width: size,
        height: size,
        borderRadius: size / 2,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: `hsl(${hue}, ${dark ? 45 : 70}%, ${dark ? 30 : 88}%)`,
      }}
    >
      <Text
        style={{ fontSize: size * 0.38, lineHeight: size * 0.46, fontWeight: '600', color: `hsl(${hue}, 60%, ${dark ? 85 : 28}%)` }}
        maxFontSizeMultiplier={1}
      >
        {initials}
      </Text>
    </View>
  );
});

export type Tone = 'neutral' | 'primary' | 'success' | 'warning' | 'danger' | 'info';

const toneColors = (c: Palette, tone: Tone): { bg: string; fg: string } => {
  switch (tone) {
    case 'primary':
      return { bg: c.primaryContainer, fg: c.onPrimaryContainer };
    case 'success':
      return { bg: c.successContainer, fg: c.success };
    case 'warning':
      return { bg: c.warningContainer, fg: c.warning };
    case 'danger':
      return { bg: c.dangerContainer, fg: c.danger };
    case 'info':
      return { bg: c.infoContainer, fg: c.info };
    case 'neutral':
      return { bg: c.fill, fg: c.textSecondary };
  }
};

/** Status pill / M3 assist chip. */
export const Pill = memo(function Pill({ label, tone = 'neutral', icon, dot = false }: { label: string; tone?: Tone; icon?: IconName; dot?: boolean }) {
  const t = useTheme();
  const { bg, fg } = toneColors(t.colors, tone);
  return (
    <View style={[styles.pill, { backgroundColor: bg, borderRadius: t.shape.chip }]}>
      {dot && <View style={[styles.dot, { backgroundColor: fg }]} />}
      {icon !== undefined && <Icon name={icon} size={13} color={fg} weight="semibold" />}
      <Text variant="caption" weight="600" style={{ color: fg }} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
});

/** Circular progress with an optional gradient stroke; animates on change. */
export const ProgressRing = memo(function ProgressRing({
  progress,
  size = 220,
  stroke = 16,
  gradient,
  trackColor,
  children,
}: {
  progress: number;
  size?: number;
  stroke?: number;
  gradient: [string, string];
  trackColor?: string;
  children?: React.ReactNode;
}) {
  const t = useTheme();
  const r = (size - stroke) / 2;
  const circumference = 2 * Math.PI * r;
  const clamped = Math.max(0, Math.min(1, Number.isFinite(progress) ? progress : 0));
  return (
    <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
      <Svg width={size} height={size} style={StyleSheet.absoluteFill}>
        <Defs>
          <LinearGradient id="ring" x1="0" y1="0" x2="1" y2="1">
            <Stop offset="0" stopColor={gradient[0]} />
            <Stop offset="1" stopColor={gradient[1]} />
          </LinearGradient>
        </Defs>
        <Circle cx={size / 2} cy={size / 2} r={r} stroke={trackColor ?? t.colors.fill} strokeWidth={stroke} fill="none" />
        <Circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          stroke="url(#ring)"
          strokeWidth={stroke}
          strokeLinecap="round"
          fill="none"
          strokeDasharray={`${circumference} ${circumference}`}
          strokeDashoffset={circumference * (1 - clamped)}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
        />
      </Svg>
      {children}
    </View>
  );
});

/** Thin linear meter for balances and capacity. */
export const Meter = memo(function Meter({ value, color, height = 6 }: { value: number; color: string; height?: number }) {
  const t = useTheme();
  const pct = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
  return (
    <View
      style={{ height, borderRadius: height, backgroundColor: t.colors.fill, overflow: 'hidden' }}
      accessibilityRole="progressbar"
      accessibilityValue={{ min: 0, max: 100, now: Math.round(pct * 100) }}
    >
      <View style={{ width: `${pct * 100}%`, height, borderRadius: height, backgroundColor: color }} />
    </View>
  );
});

/** Shimmer-free skeleton (pulse), static when reduced motion is on. */
export function Skeleton({ height = 16, width = '100%', radius, style }: { height?: number; width?: ViewStyle['width']; radius?: number; style?: StyleProp<ViewStyle> }) {
  const t = useTheme();
  const opacity = useState(() => new Animated.Value(0.55))[0];
  useEffect(() => {
    if (t.reduceMotion) return;
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, { toValue: 1, duration: 700, useNativeDriver: true }),
        Animated.timing(opacity, { toValue: 0.55, duration: 700, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [opacity, t.reduceMotion]);
  return (
    <Animated.View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[{ height, width, borderRadius: radius ?? t.shape.control, backgroundColor: t.colors.fill, opacity }, style]}
    />
  );
}

const styles = StyleSheet.create({
  pill: { flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 10, paddingVertical: 4, alignSelf: 'flex-start' },
  dot: { width: 7, height: 7, borderRadius: 4 },
});
