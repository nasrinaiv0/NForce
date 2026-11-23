import { DAY_TYPES, formatDuration, payLineFor, type DayType, type PayLine, type PayPolicy } from '@nforce/core';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { useTheme } from '@/design/theme';
import type { I18n } from '@/i18n';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

/** Human label for a pay line, e.g. "Rest day · Overtime · Night differential". */
export function payLineLabel(line: Pick<PayLine, 'dayType' | 'overtime' | 'night'>, i18n: I18n): string {
  const parts: string[] = [];
  if (line.dayType !== 'ordinary') parts.push(i18n.t(`pay.day.${line.dayType}`));
  if (line.overtime) parts.push(i18n.t('pay.overtime'));
  if (line.night) parts.push(i18n.t('pay.night'));
  return parts.length === 0 ? i18n.t('pay.regular') : parts.join(' · ');
}

export const formatMultiplier = (m: number, i18n: I18n) =>
  `${i18n.number(m * 100, { maximumFractionDigits: 1 })}%`;

/** Color per day type so categories are scannable (never color alone: labels too). */
export function dayTypeColor(dayType: DayType, colors: { primary: string; info: string; warning: string; danger: string; success: string; textSecondary: string }) {
  switch (dayType) {
    case 'ordinary':
      return colors.primary;
    case 'rest_day':
      return colors.info;
    case 'special':
    case 'special_rest_day':
      return colors.warning;
    case 'regular_holiday':
    case 'regular_holiday_rest_day':
      return colors.danger;
  }
}

export function PayLinesList({ lines, i18n, emptyLabel }: { lines: readonly PayLine[]; i18n: I18n; emptyLabel: string }) {
  const t = useTheme();
  const total = lines.reduce((n, l) => n + l.minutes, 0);
  if (lines.length === 0) {
    return (
      <Text variant="subhead" color="textSecondary">
        {emptyLabel}
      </Text>
    );
  }
  return (
    <View style={{ gap: t.space.md }}>
      <View style={[styles.stack, { backgroundColor: t.colors.fill }]} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
        {lines.map((l) => (
          <View
            key={l.code}
            style={{
              flex: l.minutes,
              backgroundColor: dayTypeColor(l.dayType, t.colors),
              opacity: l.night ? 0.55 : l.overtime ? 0.78 : 1,
            }}
          />
        ))}
      </View>
      {lines.map((l) => (
        <View key={l.code} style={styles.line} accessible accessibilityLabel={`${payLineLabel(l, i18n)}: ${formatDuration(l.minutes)}, ${formatMultiplier(l.multiplier, i18n)}`}>
          <View style={[styles.swatch, { backgroundColor: dayTypeColor(l.dayType, t.colors), opacity: l.night ? 0.55 : l.overtime ? 0.78 : 1 }]} />
          <View style={{ flex: 1 }}>
            <Text variant="subhead" numberOfLines={2}>
              {payLineLabel(l, i18n)}
            </Text>
            <Text variant="caption" color="textTertiary">
              {l.code} · {i18n.number(total > 0 ? l.minutes / total : 0, { style: 'percent' })}
            </Text>
          </View>
          <Text variant="subhead" tabular weight="600">
            {formatDuration(l.minutes)}
          </Text>
          <View style={[styles.mult, { backgroundColor: t.colors.fill }]}>
            <Text variant="caption" tabular weight="600" color="textSecondary">
              {formatMultiplier(l.multiplier, i18n)}
            </Text>
          </View>
        </View>
      ))}
    </View>
  );
}

/** Full premium matrix for the active pay policy (collapsible). */
export function RateCard({ policy, i18n }: { policy: PayPolicy; i18n: I18n }) {
  const t = useTheme();
  const [open, setOpen] = useState(false);
  const cols: { key: string; overtime: boolean; night: boolean }[] = [
    { key: 'pay.col.base', overtime: false, night: false },
    { key: 'pay.col.ot', overtime: true, night: false },
    { key: 'pay.col.nd', overtime: false, night: true },
    { key: 'pay.col.otnd', overtime: true, night: true },
  ];
  return (
    <View style={{ gap: t.space.md }}>
      <Touchable onPress={() => setOpen((v) => !v)} feedback="none" accessibilityRole="button" accessibilityState={{ expanded: open }} style={styles.rateHeader}>
        <Icon name="info" size={18} color={t.colors.primary} />
        <Text variant="headline" style={{ flex: 1 }}>
          {i18n.t('pay.rateCard')}
        </Text>
        <Icon name={open ? 'chevronUp' : 'chevronDown'} size={16} color={t.colors.textSecondary} />
      </Touchable>
      {open && (
        <View style={{ gap: t.space.sm }}>
          <View style={styles.rateRow}>
            <Text variant="caption" color="textSecondary" style={{ flex: 2.2 }} weight="700">
              {i18n.t('pay.col.day')}
            </Text>
            {cols.map((c) => (
              <Text key={c.key} variant="caption" color="textSecondary" style={styles.rateCell} weight="700" numberOfLines={1}>
                {i18n.t(c.key as never)}
              </Text>
            ))}
          </View>
          {DAY_TYPES.map((d) => (
            <View key={d} style={[styles.rateRow, { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: t.colors.separator, paddingTop: 6 }]}>
              <View style={[styles.row, { flex: 2.2 }]}>
                <View style={[styles.swatch, { backgroundColor: dayTypeColor(d, t.colors) }]} />
                <Text variant="footnote" style={{ flex: 1 }} numberOfLines={2}>
                  {d === 'ordinary' ? i18n.t('pay.regular') : i18n.t(`pay.day.${d}`)}
                </Text>
              </View>
              {cols.map((c) => (
                <Text key={c.key} variant="footnote" tabular style={styles.rateCell}>
                  {formatMultiplier(payLineFor(policy, d, c.overtime, c.night, 0).multiplier, i18n)}
                </Text>
              ))}
            </View>
          ))}
          <Text variant="caption" color="textTertiary">
            {i18n.t('pay.minimumOt', { time: formatDuration(policy.minimumOvertimeMinutes) })}
          </Text>
          <Text variant="caption" color="textTertiary">
            {i18n.t('pay.rateFootnote', { policy: policy.name })}
          </Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  stack: { flexDirection: 'row', height: 10, borderRadius: 5, overflow: 'hidden', gap: 2 },
  line: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  swatch: { width: 10, height: 10, borderRadius: 3 },
  mult: { minWidth: 58, alignItems: 'center', paddingHorizontal: 6, paddingVertical: 3, borderRadius: 6 },
  rateHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rateRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  rateCell: { flex: 1, textAlign: 'right' },
  row: { flexDirection: 'row', alignItems: 'center', gap: 6 },
});
