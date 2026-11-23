import { memo, type ReactNode } from 'react';
import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { useTheme } from '@/design/theme';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

/** Rounded content container (iOS inset-grouped card / M3 filled card). */
export const Card = memo(function Card({
  children,
  onPress,
  style,
  padded = true,
  accessibilityLabel,
  accessibilityHint,
}: {
  children: ReactNode;
  onPress?: () => void;
  style?: StyleProp<ViewStyle>;
  padded?: boolean;
  accessibilityLabel?: string;
  accessibilityHint?: string;
}) {
  const t = useTheme();
  const base: ViewStyle = {
    backgroundColor: t.colors.surface,
    borderRadius: t.shape.card,
    padding: padded ? t.space.lg : 0,
    borderCurve: 'continuous',
  };
  if (onPress === undefined) return <View style={[base, style]}>{children}</View>;
  return (
    <Touchable
      onPress={onPress}
      haptic="selection"
      style={[base, style]}
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
    >
      {children}
    </Touchable>
  );
});

/** Section title above a group of content. */
export function SectionHeader({ title, action }: { title: string; action?: { label: string; onPress: () => void } }) {
  const t = useTheme();
  return (
    <View style={[styles.sectionHeader, { paddingHorizontal: t.space.xs }]}>
      <Text
        variant={t.flavor === 'ios' ? 'title2' : 'headline'}
        accessibilityRole="header"
      >
        {title}
      </Text>
      {action !== undefined && (
        <Touchable onPress={action.onPress} feedback="none" hitSlop={10} accessibilityLabel={action.label}>
          <Text variant="subhead" color="primary" weight="600">
            {action.label}
          </Text>
        </Touchable>
      )}
    </View>
  );
}

/** Grouped list section: iOS inset-grouped table / Android list with dividers. */
export function ListSection({ title, footer, children }: { title?: string; footer?: string; children: ReactNode }) {
  const t = useTheme();
  return (
    <View style={{ gap: t.space.sm }}>
      {title !== undefined && (
        <Text
          variant={t.flavor === 'ios' ? 'footnote' : 'label'}
          color={t.flavor === 'ios' ? 'textSecondary' : 'primary'}
          style={{ paddingHorizontal: t.space.lg, textTransform: t.flavor === 'ios' ? 'uppercase' : 'none' }}
          accessibilityRole="header"
        >
          {title}
        </Text>
      )}
      <View style={{ backgroundColor: t.colors.surface, borderRadius: t.shape.card, overflow: 'hidden', borderCurve: 'continuous' }}>
        {children}
      </View>
      {footer !== undefined && (
        <Text variant="footnote" color="textSecondary" style={{ paddingHorizontal: t.space.lg }}>
          {footer}
        </Text>
      )}
    </View>
  );
}

export interface ListRowProps {
  title: string;
  subtitle?: string;
  icon?: IconName;
  iconTint?: string;
  value?: string;
  trailing?: ReactNode;
  leading?: ReactNode;
  onPress?: () => void;
  chevron?: boolean;
  last?: boolean;
  destructive?: boolean;
  accessibilityHint?: string;
}

export const ListRow = memo(function ListRow({
  title,
  subtitle,
  icon,
  iconTint,
  value,
  trailing,
  leading,
  onPress,
  chevron = onPress !== undefined,
  last = false,
  destructive = false,
  accessibilityHint,
}: ListRowProps) {
  const t = useTheme();
  const ios = t.flavor === 'ios';
  const tint = iconTint ?? t.colors.primary;
  const content = (
    <View style={[styles.row, { minHeight: t.shape.rowMinHeight + (subtitle !== undefined ? 12 : 0), paddingLeft: t.space.lg }]}>
      {leading}
      {icon !== undefined &&
        (ios ? (
          <View style={[styles.iosIcon, { backgroundColor: tint }]}>
            <Icon name={icon} size={17} color="#FFFFFF" weight="semibold" />
          </View>
        ) : (
          <Icon name={icon} size={24} color={t.colors.textSecondary} />
        ))}
      <View
        style={[
          styles.rowBody,
          { paddingRight: t.space.lg, gap: t.space.sm },
          ios && !last && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
        ]}
      >
        <View style={{ flex: 1, paddingVertical: t.space.md }}>
          <Text variant="body" color={destructive ? 'danger' : 'text'} numberOfLines={2}>
            {title}
          </Text>
          {subtitle !== undefined && (
            <Text variant={ios ? 'footnote' : 'subhead'} color="textSecondary" numberOfLines={2}>
              {subtitle}
            </Text>
          )}
        </View>
        {value !== undefined && (
          <Text variant={ios ? 'body' : 'subhead'} color="textSecondary" numberOfLines={1}>
            {value}
          </Text>
        )}
        {trailing}
        {chevron && ios && <Icon name="chevron" size={14} color={t.colors.textTertiary} weight="semibold" />}
      </View>
    </View>
  );
  if (onPress === undefined) return content;
  return (
    <Touchable
      onPress={onPress}
      feedback="highlight"
      haptic="selection"
      accessibilityRole="button"
      accessibilityLabel={value !== undefined ? `${title}, ${value}` : title}
      accessibilityHint={accessibilityHint}
    >
      {content}
    </Touchable>
  );
});

const styles = StyleSheet.create({
  sectionHeader: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 14 },
  rowBody: { flex: 1, flexDirection: 'row', alignItems: 'center', alignSelf: 'stretch' },
  iosIcon: { width: 30, height: 30, borderRadius: 8, alignItems: 'center', justifyContent: 'center', borderCurve: 'continuous' },
});
