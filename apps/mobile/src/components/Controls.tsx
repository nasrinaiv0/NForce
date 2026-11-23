import { memo } from 'react';
import { StyleSheet, Switch, View } from 'react-native';

import { useTheme } from '@/design/theme';
import { Icon, type IconName } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export interface Segment<T extends string> {
  value: T;
  label: string;
}

/**
 * iOS segmented control / Material 3 segmented buttons. Exposed to assistive
 * tech as a tab list with selected state.
 */
export function SegmentedControl<T extends string>({
  segments,
  value,
  onChange,
}: {
  segments: readonly Segment<T>[];
  value: T;
  onChange: (value: T) => void;
}) {
  const t = useTheme();
  const ios = t.flavor === 'ios';
  return (
    <View
      accessibilityRole="tablist"
      style={[
        styles.segments,
        ios
          ? { backgroundColor: t.colors.fill, borderRadius: 999, padding: 3 }
          : { borderRadius: 999, borderWidth: 1, borderColor: t.colors.outline, overflow: 'hidden' },
      ]}
    >
      {segments.map((s, i) => {
        const selected = s.value === value;
        return (
          <Touchable
            key={s.value}
            onPress={() => !selected && onChange(s.value)}
            haptic="selection"
            feedback={ios ? 'none' : 'highlight'}
            accessibilityRole="tab"
            accessibilityState={{ selected }}
            accessibilityLabel={s.label}
            style={[
              styles.segment,
              ios
                ? [{ borderRadius: 999, minHeight: 32 }, selected && { backgroundColor: t.colors.surfaceRaised, ...shadow }]
                : [
                    { minHeight: 40 },
                    i > 0 && { borderLeftWidth: 1, borderLeftColor: t.colors.outline },
                    selected && { backgroundColor: t.colors.primaryContainer },
                  ],
            ]}
          >
            <View style={styles.segmentInner}>
              {!ios && selected && <Icon name="check" size={16} color={t.colors.onPrimaryContainer} />}
              <Text
                variant={ios ? 'footnote' : 'label'}
                weight={selected ? '600' : '500'}
                style={{ color: !ios && selected ? t.colors.onPrimaryContainer : t.colors.text }}
                numberOfLines={1}
              >
                {s.label}
              </Text>
            </View>
          </Touchable>
        );
      })}
    </View>
  );
}

const shadow = {
  shadowColor: '#000',
  shadowOpacity: 0.12,
  shadowRadius: 4,
  shadowOffset: { width: 0, height: 2 },
  elevation: 2,
};

/** Selectable chip (M3 filter chip / iOS capsule toggle). */
export const Chip = memo(function Chip({
  label,
  selected,
  onPress,
  icon,
}: {
  label: string;
  selected: boolean;
  onPress: () => void;
  icon?: IconName;
}) {
  const t = useTheme();
  const ios = t.flavor === 'ios';
  const fg = selected ? (ios ? t.colors.onPrimary : t.colors.onPrimaryContainer) : t.colors.text;
  return (
    <Touchable
      onPress={onPress}
      haptic="selection"
      accessibilityRole="checkbox"
      accessibilityState={{ checked: selected }}
      accessibilityLabel={label}
      style={[
        styles.chip,
        { borderRadius: t.shape.chip, minHeight: ios ? 34 : 32 },
        selected
          ? { backgroundColor: ios ? t.colors.primary : t.colors.primaryContainer }
          : ios
            ? { backgroundColor: t.colors.fill }
            : { borderWidth: 1, borderColor: t.colors.outline },
      ]}
    >
      <View style={styles.segmentInner}>
        {(icon !== undefined || (!ios && selected)) && <Icon name={selected && !ios ? 'check' : (icon ?? 'check')} size={16} color={fg} />}
        <Text variant={ios ? 'subhead' : 'label'} weight="500" style={{ color: fg }}>
          {label}
        </Text>
      </View>
    </Touchable>
  );
});

/** Round iOS checkmark / Material checkbox, with a generous touch target. */
export const Checkbox = memo(function Checkbox({ checked, onToggle, label }: { checked: boolean; onToggle: () => void; label: string }) {
  const t = useTheme();
  const ios = t.flavor === 'ios';
  return (
    <Touchable
      onPress={onToggle}
      haptic={checked ? 'light' : 'success'}
      feedback="none"
      hitSlop={12}
      accessibilityRole="checkbox"
      accessibilityState={{ checked }}
      accessibilityLabel={label}
      style={{ width: t.minTouch - 12, height: t.minTouch - 12, alignItems: 'center', justifyContent: 'center' }}
    >
      {ios ? (
        <Icon name={checked ? 'checkCircle' : 'circle'} size={24} color={checked ? t.colors.primary : t.colors.textTertiary} />
      ) : (
        <View
          style={[
            styles.mdBox,
            checked ? { backgroundColor: t.colors.primary, borderColor: t.colors.primary } : { borderColor: t.colors.textSecondary },
          ]}
        >
          {checked && <Icon name="check" size={16} color={t.colors.onPrimary} weight="bold" />}
        </View>
      )}
    </Touchable>
  );
});

/** Native switch with platform-tuned colors. */
export function Toggle({ value, onValueChange, label }: { value: boolean; onValueChange: (v: boolean) => void; label: string }) {
  const t = useTheme();
  return (
    <Switch
      value={value}
      onValueChange={onValueChange}
      accessibilityLabel={label}
      trackColor={{ false: t.colors.fill, true: t.flavor === 'ios' ? t.colors.success : t.colors.primary }}
      thumbColor={t.flavor === 'android' ? (value ? t.colors.onPrimary : t.colors.outline) : undefined}
      ios_backgroundColor={t.colors.fill}
    />
  );
}

/** Floating action button (Android only — iOS uses a toolbar/header action). */
export function Fab({ icon, label, onPress }: { icon: IconName; label: string; onPress: () => void }) {
  const t = useTheme();
  if (t.flavor !== 'android') return null;
  return (
    <View style={styles.fabWrap} pointerEvents="box-none">
      <Touchable
        onPress={onPress}
        haptic="medium"
        accessibilityLabel={label}
        style={[styles.fab, { backgroundColor: t.colors.primaryContainer }]}
      >
        <View style={styles.segmentInner}>
          <Icon name={icon} size={24} color={t.colors.onPrimaryContainer} />
          <Text variant="label" style={{ color: t.colors.onPrimaryContainer }}>
            {label}
          </Text>
        </View>
      </Touchable>
    </View>
  );
}

const styles = StyleSheet.create({
  segments: { flexDirection: 'row' },
  segment: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 8 },
  segmentInner: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  chip: { paddingHorizontal: 14, alignItems: 'center', justifyContent: 'center' },
  mdBox: { width: 20, height: 20, borderRadius: 3, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
  fabWrap: { position: 'absolute', right: 16, bottom: 16 },
  fab: {
    minHeight: 56,
    borderRadius: 16,
    paddingHorizontal: 18,
    justifyContent: 'center',
    shadowColor: '#000',
    shadowOpacity: 0.18,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 3 },
    elevation: 3,
  },
});
