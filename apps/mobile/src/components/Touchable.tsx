import { memo, useCallback, useState } from 'react';
import { Animated, Pressable, type PressableProps, type StyleProp, type ViewStyle } from 'react-native';

import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

export interface TouchableProps extends Omit<PressableProps, 'style'> {
  style?: StyleProp<ViewStyle>;
  /** Visual press feedback: `scale` for cards/buttons, `highlight` for rows. */
  feedback?: 'scale' | 'highlight' | 'none';
  haptic?: keyof typeof haptics | false;
  rippleColor?: string;
  /** Ripple bounded to the view (default) or radiating (icon buttons). */
  borderlessRipple?: boolean;
}

/**
 * Platform-correct press feedback:
 * - Android: Material ripple (state layer) rendered natively.
 * - iOS/web: a quick spring scale or highlight, driven on the native thread.
 * Reduced motion disables the scale animation. Layout styles (flex, margins)
 * apply directly to the pressable, so it composes like a plain View.
 */
export const Touchable = memo(function Touchable({
  style,
  feedback = 'scale',
  haptic = false,
  rippleColor,
  borderlessRipple = false,
  onPressIn,
  onPressOut,
  onPress,
  disabled,
  children,
  ...rest
}: TouchableProps) {
  const t = useTheme();
  const scale = useState(() => new Animated.Value(1))[0];
  const [pressed, setPressed] = useState(false);
  const ios = t.flavor === 'ios';
  const useScale = ios && feedback === 'scale' && !t.reduceMotion;

  const animateTo = useCallback(
    (value: number) =>
      Animated.spring(scale, { toValue: value, useNativeDriver: true, speed: 50, bounciness: value === 1 ? 6 : 0 }).start(),
    [scale],
  );

  return (
    <AnimatedPressable
      accessibilityRole="button"
      disabled={disabled}
      android_ripple={
        !ios && feedback !== 'none'
          ? { color: rippleColor ?? t.colors.ripple, borderless: borderlessRipple, foreground: true }
          : undefined
      }
      onPressIn={(e) => {
        setPressed(true);
        if (useScale) animateTo(0.97);
        onPressIn?.(e);
      }}
      onPressOut={(e) => {
        setPressed(false);
        if (useScale) animateTo(1);
        onPressOut?.(e);
      }}
      onPress={(e) => {
        if (haptic !== false) haptics[haptic]();
        onPress?.(e);
      }}
      style={[
        style,
        !borderlessRipple && { overflow: 'hidden' },
        useScale && { transform: [{ scale }] },
        pressed && ios && feedback === 'highlight' && { backgroundColor: t.colors.fill },
        pressed && ios && feedback === 'scale' && { opacity: 0.9 },
        disabled === true && { opacity: 0.45 },
      ]}
      {...rest}
    >
      {children}
    </AnimatedPressable>
  );
});
