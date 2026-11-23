import * as Haptics from 'expo-haptics';
import { Platform } from 'react-native';

import { preferencesStore } from '@/state/preferences';

/**
 * Semantic haptics. Calls are fire-and-forget, respect the user's preference
 * and are no-ops where unsupported, so they can never throw into UI code.
 */
const enabled = () => Platform.OS !== 'web' && preferencesStore.get().haptics;
const safe = (p: Promise<void>) => p.catch(() => undefined);

export const haptics = {
  selection: () => enabled() && void safe(Haptics.selectionAsync()),
  light: () => enabled() && void safe(Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)),
  medium: () => enabled() && void safe(Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)),
  success: () => enabled() && void safe(Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)),
  warning: () => enabled() && void safe(Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)),
  error: () => enabled() && void safe(Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)),
};
