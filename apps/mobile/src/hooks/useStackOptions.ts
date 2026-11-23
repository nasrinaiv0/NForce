import { useMemo } from 'react';
import { Platform } from 'react-native';

import { useTheme } from '@/design/theme';

/**
 * Native stack header options per flavor:
 * - iOS: collapsing large titles over a translucent, blurred bar.
 * - Android: Material 3 top app bar on the background surface.
 */
export function useStackOptions() {
  const t = useTheme();
  return useMemo(
    () =>
      t.flavor === 'ios'
        ? {
            headerLargeTitleEnabled: true,
            // Native iOS insets content under the translucent bar; web cannot.
            headerTransparent: Platform.OS === 'ios',
            ...(Platform.OS === 'ios' ? {} : { headerStyle: { backgroundColor: t.colors.background } }),
            headerBlurEffect: t.scheme === 'dark' ? ('systemChromeMaterialDark' as const) : ('systemChromeMaterialLight' as const),
            headerShadowVisible: false,
            headerLargeTitleShadowVisible: false,
            headerLargeStyle: { backgroundColor: t.colors.background },
            headerTintColor: t.colors.primary,
            headerTitleStyle: { color: t.colors.text },
            headerLargeTitleStyle: { color: t.colors.text },
            contentStyle: { backgroundColor: t.colors.background },
          }
        : {
            headerShadowVisible: false,
            headerStyle: { backgroundColor: t.colors.background },
            headerTintColor: t.colors.text,
            headerTitleStyle: { color: t.colors.text, fontSize: 22, fontWeight: '400' as const },
            contentStyle: { backgroundColor: t.colors.background },
            animation: 'fade_from_bottom' as const,
          },
    [t],
  );
}
