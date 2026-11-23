import { memo } from 'react';
import { ActivityIndicator, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { useTheme } from '@/design/theme';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export type ButtonVariant = 'filled' | 'tonal' | 'outlined' | 'plain' | 'destructive';

export interface ButtonProps {
  title: string;
  onPress: () => void;
  variant?: ButtonVariant;
  icon?: IconName;
  loading?: boolean;
  disabled?: boolean;
  size?: 'regular' | 'large' | 'small';
  style?: StyleProp<ViewStyle>;
  accessibilityHint?: string;
  testID?: string;
}

/**
 * Buttons map to native conventions: iOS capsule "filled / gray / plain"
 * styles, Material 3 "filled / tonal / outlined / text" buttons on Android.
 */
export const Button = memo(function Button({
  title,
  onPress,
  variant = 'filled',
  icon,
  loading = false,
  disabled = false,
  size = 'regular',
  style,
  accessibilityHint,
  testID,
}: ButtonProps) {
  const t = useTheme();
  const c = t.colors;
  const palette: Record<ButtonVariant, { bg: string; fg: string; border?: string }> = {
    filled: { bg: c.primary, fg: c.onPrimary },
    tonal: { bg: c.tonal, fg: c.onTonal },
    outlined: { bg: 'transparent', fg: c.primary, border: c.outline },
    plain: { bg: 'transparent', fg: c.primary },
    destructive: { bg: c.dangerContainer, fg: c.danger },
  };
  const { bg, fg, border } = palette[variant];
  const height = size === 'large' ? t.shape.buttonHeight + 6 : size === 'small' ? 36 : t.shape.buttonHeight;
  const label = t.flavor === 'android' ? 'label' : size === 'small' ? 'subhead' : 'headline';

  return (
    <Touchable
      onPress={onPress}
      disabled={disabled || loading}
      haptic="light"
      testID={testID}
      accessibilityLabel={title}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled: disabled || loading, busy: loading }}
      hitSlop={size === 'small' ? 6 : 0}
      style={[
        styles.base,
        {
          minHeight: height,
          borderRadius: t.shape.button,
          backgroundColor: bg,
          paddingHorizontal: variant === 'plain' ? t.space.sm : size === 'small' ? t.space.lg : t.space.xxl,
        },
        border !== undefined && { borderWidth: t.shape.hairline * 2, borderColor: border },
        style,
      ]}
    >
      <View style={styles.row}>
        {loading ? (
          <ActivityIndicator color={fg} size="small" />
        ) : (
          icon !== undefined && <Icon name={icon} size={size === 'small' ? 16 : 19} color={fg} weight="semibold" />
        )}
        <Text variant={label} weight={t.flavor === 'ios' ? '600' : '500'} style={{ color: fg }} numberOfLines={1}>
          {title}
        </Text>
      </View>
    </Touchable>
  );
});

const styles = StyleSheet.create({
  base: { alignItems: 'center', justifyContent: 'center' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
});
