import { memo, type ReactNode } from 'react';
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import Svg, { Circle, Defs, LinearGradient, Rect, Stop } from 'react-native-svg';

import { useTheme } from '@/design/theme';
import { Touchable } from './Touchable';

/** Brand moment: gradient card with soft decorative orbs. Use sparingly. */
export const HeroCard = memo(function HeroCard({
  children,
  onPress,
  accessibilityLabel,
  style,
}: {
  children: ReactNode;
  onPress?: () => void;
  accessibilityLabel?: string;
  style?: StyleProp<ViewStyle>;
}) {
  const t = useTheme();
  const body = (
    <>
      <Svg style={StyleSheet.absoluteFill} preserveAspectRatio="none" viewBox="0 0 100 100" accessible={false}>
        <Defs>
          <LinearGradient id="hero" x1="0" y1="0" x2="1" y2="1">
            <Stop offset="0" stopColor={t.colors.heroStart} />
            <Stop offset="1" stopColor={t.colors.heroEnd} />
          </LinearGradient>
        </Defs>
        <Rect x="0" y="0" width="100" height="100" fill="url(#hero)" />
        <Circle cx="92" cy="8" r="30" fill="#FFFFFF" fillOpacity={0.08} />
        <Circle cx="8" cy="108" r="36" fill="#FFFFFF" fillOpacity={0.06} />
      </Svg>
      <View style={{ padding: t.space.xl, gap: t.space.md }}>{children}</View>
    </>
  );
  const base = [styles.card, { borderRadius: t.shape.card + 4 }, style];
  return onPress === undefined ? (
    <View style={base}>{body}</View>
  ) : (
    <Touchable onPress={onPress} haptic="selection" style={base} accessibilityLabel={accessibilityLabel} rippleColor="rgba(255,255,255,0.2)">
      {body}
    </Touchable>
  );
});

const styles = StyleSheet.create({
  card: { overflow: 'hidden', borderCurve: 'continuous' },
});
