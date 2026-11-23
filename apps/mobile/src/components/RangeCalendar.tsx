import { addDays, isoWeekday, parseDateKey, toDateKey, type DateKey } from '@nforce/core';
import { memo, useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export interface DateRange {
  start?: DateKey;
  end?: DateKey;
}

const monthStart = (key: DateKey): DateKey => {
  const { year, month } = parseDateKey(key);
  return toDateKey(year, month, 1);
};
const shiftMonth = (key: DateKey, delta: number): DateKey => {
  const { year, month } = parseDateKey(key);
  const m = month - 1 + delta;
  return toDateKey(year + Math.floor(m / 12), ((m % 12) + 12) % 12 + 1, 1);
};
const daysInMonth = (key: DateKey) => {
  const { year, month } = parseDateKey(key);
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
};

/** Next range after tapping `day` (tap start → tap end; tap again to restart). */
export function nextRange(range: DateRange, day: DateKey): DateRange {
  if (range.start === undefined || range.end !== undefined) return { start: day };
  if (day < range.start) return { start: day };
  return { start: range.start, end: day };
}

/** Month grid range picker, Monday-first (ISO), with past dates disabled. */
export const RangeCalendar = memo(function RangeCalendar({
  value,
  onChange,
  minDate,
}: {
  value: DateRange;
  onChange: (range: DateRange) => void;
  minDate: DateKey;
}) {
  const t = useTheme();
  const i18n = useI18n();
  const [visible, setVisible] = useState<DateKey>(() => monthStart(value.start ?? minDate));
  const canGoBack = visible > monthStart(minDate);

  const cells = useMemo(() => {
    const lead = isoWeekday(visible) - 1;
    const n = daysInMonth(visible);
    return [...Array<null>(lead).fill(null), ...Array.from({ length: n }, (_, i) => addDays(visible, i))];
  }, [visible]);

  // 2024-01-01 was a Monday: a stable anchor for localized weekday initials.
  const weekdays = useMemo(() => Array.from({ length: 7 }, (_, i) => i18n.date(addDays('2024-01-01', i), { weekday: 'narrow' })), [i18n]);
  const end = value.end ?? value.start;

  return (
    <View style={{ gap: t.space.md }}>
      <View style={styles.header}>
        <Text variant="headline" accessibilityRole="header">
          {i18n.date(visible, { month: 'long', year: 'numeric' })}
        </Text>
        <View style={styles.nav}>
          <NavButton icon="back" disabled={!canGoBack} onPress={() => setVisible(shiftMonth(visible, -1))} label={i18n.t('common.prevMonth')} />
          <NavButton icon="chevron" onPress={() => setVisible(shiftMonth(visible, 1))} label={i18n.t('common.nextMonth')} />
        </View>
      </View>
      <View style={styles.grid}>
        {weekdays.map((w, i) => (
          <View key={`w${i}`} style={styles.cell}>
            <Text variant="caption" color="textTertiary" weight="600">
              {w}
            </Text>
          </View>
        ))}
        {cells.map((d, i) => {
          if (d === null) return <View key={`b${i}`} style={styles.cell} />;
          const disabled = d < minDate;
          const isEdge = d === value.start || d === end;
          const inRange = value.start !== undefined && end !== undefined && d > value.start && d < end;
          return (
            <View key={d} style={styles.cell}>
              {inRange && <View style={[StyleSheet.absoluteFill, styles.band, { backgroundColor: t.colors.primaryContainer }]} />}
              <Touchable
                onPress={() => onChange(nextRange(value, d))}
                disabled={disabled}
                feedback="none"
                haptic="selection"
                accessibilityRole="button"
                accessibilityState={{ selected: isEdge || inRange, disabled }}
                accessibilityLabel={i18n.date(d, { weekday: 'long', month: 'long', day: 'numeric' })}
                style={[styles.day, isEdge && { backgroundColor: t.colors.primary }]}
              >
                <Text
                  variant="callout"
                  tabular
                  weight={isEdge ? '700' : '400'}
                  style={{ color: isEdge ? t.colors.onPrimary : inRange ? t.colors.onPrimaryContainer : t.colors.text }}
                >
                  {Number(d.slice(8))}
                </Text>
              </Touchable>
            </View>
          );
        })}
      </View>
    </View>
  );
});

function NavButton({ icon, onPress, disabled, label }: { icon: 'back' | 'chevron'; onPress: () => void; disabled?: boolean; label: string }) {
  const t = useTheme();
  return (
    <Touchable
      onPress={onPress}
      disabled={disabled}
      feedback="highlight"
      borderlessRipple
      accessibilityLabel={label}
      style={[styles.navButton, { backgroundColor: t.colors.fill }]}
    >
      <View style={icon === 'back' ? { transform: [{ scaleX: -1 }] } : undefined}>
        <Icon name="chevron" size={16} color={t.colors.primary} weight="semibold" />
      </View>
    </Touchable>
  );
}

const styles = StyleSheet.create({
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  nav: { flexDirection: 'row', gap: 8 },
  navButton: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
  grid: { flexDirection: 'row', flexWrap: 'wrap' },
  cell: { width: `${100 / 7}%`, aspectRatio: 1, alignItems: 'center', justifyContent: 'center' },
  band: { marginVertical: 4 },
  day: { width: '86%', height: '86%', borderRadius: 999, alignItems: 'center', justifyContent: 'center' },
});
