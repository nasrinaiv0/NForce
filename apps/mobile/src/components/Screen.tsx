import { useCallback, useState, type ReactNode } from 'react';
import { RefreshControl, ScrollView, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { Button } from './Button';
import { Skeleton } from './Display';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';

/**
 * Scrollable screen body. On iOS it cooperates with the native large-title
 * header (automatic content insets); pull-to-refresh is native on both.
 */
export function Screen({
  children,
  onRefresh,
  contentStyle,
  footer,
}: {
  children: ReactNode;
  onRefresh?: () => Promise<unknown>;
  contentStyle?: StyleProp<ViewStyle>;
  footer?: ReactNode;
}) {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  const [refreshing, setRefreshing] = useState(false);
  const refresh = useCallback(async () => {
    if (onRefresh === undefined) return;
    setRefreshing(true);
    try {
      await onRefresh();
    } finally {
      setRefreshing(false);
    }
  }, [onRefresh]);

  return (
    <View style={{ flex: 1, backgroundColor: t.colors.background }}>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        style={{ backgroundColor: t.colors.background }}
        contentContainerStyle={[
          styles.content,
          { padding: t.space.lg, gap: t.space.xxl, paddingBottom: insets.bottom + 96 },
          contentStyle,
        ]}
        refreshControl={
          onRefresh !== undefined ? (
            <RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={t.colors.primary} colors={[t.colors.primary]} />
          ) : undefined
        }
      >
        {children}
      </ScrollView>
      {footer}
    </View>
  );
}

export function EmptyState({ icon, title, body, action }: { icon: IconName; title: string; body?: string; action?: ReactNode }) {
  const t = useTheme();
  return (
    <View style={[styles.state, { gap: t.space.md }]} accessible accessibilityLabel={body !== undefined ? `${title}. ${body}` : title}>
      <View style={[styles.stateIcon, { backgroundColor: t.colors.primaryContainer }]}>
        <Icon name={icon} size={30} color={t.colors.onPrimaryContainer} />
      </View>
      <Text variant="headline" align="center">
        {title}
      </Text>
      {body !== undefined && (
        <Text variant="subhead" color="textSecondary" align="center" style={{ maxWidth: 300 }}>
          {body}
        </Text>
      )}
      {action}
    </View>
  );
}

export function ErrorState({ onRetry, message }: { onRetry: () => void; message?: string }) {
  const { t } = useI18n();
  return (
    <EmptyState
      icon="warning"
      title={t('common.errorTitle')}
      body={message ?? t('common.errorBody')}
      action={<Button title={t('common.retry')} variant="tonal" onPress={onRetry} size="small" />}
    />
  );
}

export function LoadingBlock({ rows = 3, height = 72 }: { rows?: number; height?: number }) {
  const t = useTheme();
  const { t: tr } = useI18n();
  return (
    <View style={{ gap: t.space.md }} accessibilityLabel={tr('common.loading')} accessibilityRole="progressbar">
      {Array.from({ length: rows }, (_, i) => (
        <Skeleton key={i} height={height} radius={t.shape.card} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  content: { flexGrow: 1 },
  state: { alignItems: 'center', justifyContent: 'center', paddingVertical: 48, paddingHorizontal: 24 },
  stateIcon: { width: 64, height: 64, borderRadius: 32, alignItems: 'center', justifyContent: 'center' },
});
