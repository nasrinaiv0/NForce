import { memo } from 'react';
import { Text as RNText, type TextProps as RNTextProps, type TextStyle } from 'react-native';

import { useTheme } from '@/design/theme';
import type { Palette, TypeVariant } from '@/design/tokens';

type ColorToken = { [K in keyof Palette]: Palette[K] extends string ? K : never }[keyof Palette];

export interface TextProps extends RNTextProps {
  variant?: TypeVariant;
  color?: ColorToken;
  weight?: TextStyle['fontWeight'];
  align?: TextStyle['textAlign'];
  /** Monospaced digits for timers, totals and tables. */
  tabular?: boolean;
}

/**
 * Typography primitive bound to the platform type ramp. Supports Dynamic Type /
 * font scaling up to 2x (capped so dense layouts never break).
 */
export const Text = memo(function Text({
  variant = 'body',
  color = 'text',
  weight,
  align,
  tabular,
  style,
  maxFontSizeMultiplier = 2,
  ...rest
}: TextProps) {
  const t = useTheme();
  return (
    <RNText
      maxFontSizeMultiplier={maxFontSizeMultiplier}
      style={[
        t.type[variant],
        { color: t.colors[color] },
        weight !== undefined && { fontWeight: weight },
        align !== undefined && { textAlign: align },
        tabular === true && { fontVariant: ['tabular-nums'] },
        style,
      ]}
      {...rest}
    />
  );
});
