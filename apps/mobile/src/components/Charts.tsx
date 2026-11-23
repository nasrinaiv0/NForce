import { useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, View, type LayoutChangeEvent } from 'react-native';
import Svg, { Circle, Line, Path, Text as SvgText } from 'react-native-svg';

import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

/**
 * Chart primitives following the NForce data-viz rules:
 * one y-axis, thin marks (2px lines, 4px rounded bar ends), legend + direct
 * labels for ≥2 series, recessive grid, a selected-point readout (tap / hover)
 * and a table view, so values never depend on color or pointer alone.
 */

/** Validated categorical slots 1–3 (blue, orange, aqua) per scheme. */
export const SERIES_COLORS = {
  light: ['#2a78d6', '#eb6834', '#1baf7a'],
  dark: ['#3987e5', '#d95926', '#199e70'],
} as const;

export function useSeriesColors(): readonly string[] {
  const t = useTheme();
  return SERIES_COLORS[t.scheme];
}

function useWidth(initial = 320): [number, (e: LayoutChangeEvent) => void] {
  const [w, setW] = useState(initial);
  return [w, (e) => setW(Math.max(120, Math.round(e.nativeEvent.layout.width)))];
}

export interface Series {
  readonly name: string;
  readonly values: readonly number[];
}

/** Multi-series line chart on ONE shared axis (values in the same unit). */
export function LineChart({
  labels,
  series,
  format,
  min,
  max,
  height = 180,
  target,
  title,
}: {
  labels: readonly string[];
  series: readonly Series[];
  format: (v: number) => string;
  min?: number;
  max?: number;
  height?: number;
  target?: { value: number; label: string };
  title: string;
}) {
  const t = useTheme();
  const colors = useSeriesColors();
  const [width, onLayout] = useWidth();
  const [selected, setSelected] = useState(labels.length - 1);
  const [showTable, setShowTable] = useState(false);
  const all = series.flatMap((s) => s.values).concat(target !== undefined ? [target.value] : []);
  const lo = min ?? Math.min(...all);
  const hi = max ?? Math.max(...all);
  const span = hi - lo || 1;
  const pad = { l: 8, r: 8, t: 12, b: 22 };
  const plotW = width - pad.l - pad.r;
  const plotH = height - pad.t - pad.b;
  const x = (i: number) => pad.l + (labels.length <= 1 ? plotW / 2 : (i / (labels.length - 1)) * plotW);
  const y = (v: number) => pad.t + plotH - ((v - lo) / span) * plotH;
  const sel = Math.min(Math.max(selected, 0), labels.length - 1);

  return (
    <View style={{ gap: t.space.sm }}>
      <View style={styles.legendRow}>
        <View style={styles.legend} accessibilityRole="text">
          {series.length > 1 &&
            series.map((s, i) => (
              <View key={s.name} style={styles.legendItem}>
                <View style={[styles.legendSwatch, { backgroundColor: colors[i % colors.length] }]} />
                <Text variant="caption" color="textSecondary">
                  {s.name}
                </Text>
              </View>
            ))}
        </View>
        <TableToggle on={showTable} onToggle={() => setShowTable((v) => !v)} />
      </View>
      {/* Readout for the selected point: the accessible, color-free value channel. */}
      <View style={styles.readout} accessibilityLiveRegion="polite">
        <Text variant="footnote" weight="700">
          {labels[sel]}
        </Text>
        {series.map((s, i) => (
          <Text key={s.name} variant="footnote" color="textSecondary" tabular>
            {series.length > 1 ? `${s.name} ` : ''}
            <Text variant="footnote" weight="600" tabular>
              {format(s.values[sel] ?? 0)}
            </Text>
            {i < series.length - 1 ? '  ·' : ''}
          </Text>
        ))}
      </View>
      {showTable ? (
        <DataRows title={title} labels={labels} series={series} format={format} />
      ) : (
        <View onLayout={onLayout} accessibilityLabel={title}>
          <Svg width={width} height={height}>
            {[0, 0.5, 1].map((f) => (
              <Line key={f} x1={pad.l} x2={width - pad.r} y1={pad.t + plotH * f} y2={pad.t + plotH * f} stroke={t.colors.separator} strokeWidth={1} />
            ))}
            {target !== undefined && (
              <>
                <Line x1={pad.l} x2={width - pad.r} y1={y(target.value)} y2={y(target.value)} stroke={t.colors.textTertiary} strokeWidth={1} strokeDasharray="4 4" />
                <SvgText x={width - pad.r} y={y(target.value) - 4} fill={t.colors.textSecondary} fontSize={10} textAnchor="end">
                  {target.label}
                </SvgText>
              </>
            )}
            <Line x1={x(sel)} x2={x(sel)} y1={pad.t} y2={pad.t + plotH} stroke={t.colors.outline} strokeWidth={1} />
            {series.map((s, si) => {
              const d = s.values.map((v, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
              return <Path key={s.name} d={d} stroke={colors[si % colors.length]} strokeWidth={2} fill="none" strokeLinejoin="round" strokeLinecap="round" />;
            })}
            {series.map((s, si) => (
              <Circle key={`${s.name}-sel`} cx={x(sel)} cy={y(s.values[sel] ?? 0)} r={4.5} fill={colors[si % colors.length]} stroke={t.colors.surface} strokeWidth={2} />
            ))}
            {labels.map((l, i) =>
              i === 0 || i === labels.length - 1 || i === sel ? (
                <SvgText key={l} x={x(i)} y={height - 6} fill={t.colors.textSecondary} fontSize={10} textAnchor={i === 0 ? 'start' : i === labels.length - 1 ? 'end' : 'middle'}>
                  {l}
                </SvgText>
              ) : null,
            )}
          </Svg>
          {/* Hit targets: full-height columns, larger than the marks. */}
          <View style={[StyleSheet.absoluteFill, styles.hitRow]}>
            {labels.map((l, i) => (
              <Pressable
                key={l}
                style={styles.hit}
                onPress={() => setSelected(i)}
                onHoverIn={() => setSelected(i)}
                accessibilityRole="button"
                accessibilityLabel={`${l}: ${series.map((s) => `${s.name} ${format(s.values[i] ?? 0)}`).join(', ')}`}
              />
            ))}
          </View>
        </View>
      )}
    </View>
  );
}

/** Vertical bars, single series (magnitude); selected bar is read out. */
export function BarChart({
  labels,
  values,
  format,
  height = 150,
  title,
  color,
}: {
  labels: readonly string[];
  values: readonly number[];
  format: (v: number) => string;
  height?: number;
  title: string;
  color?: string;
}) {
  const t = useTheme();
  const [width, onLayout] = useWidth();
  const [selected, setSelected] = useState(values.length - 1);
  const [showTable, setShowTable] = useState(false);
  const hi = Math.max(1, ...values);
  const pad = { t: 8, b: 20 };
  const plotH = height - pad.t - pad.b;
  const slot = width / Math.max(1, values.length);
  const barW = Math.max(6, Math.min(28, slot * 0.6));
  const fill = color ?? t.colors.primary;
  const sel = Math.min(Math.max(selected, 0), values.length - 1);

  return (
    <View style={{ gap: t.space.sm }}>
      <View style={styles.legendRow}>
        <Text variant="footnote" color="textSecondary">
          <Text variant="footnote" weight="700">
            {labels[sel]}
          </Text>
          {'  '}
          <Text variant="footnote" weight="600" tabular>
            {format(values[sel] ?? 0)}
          </Text>
        </Text>
        <TableToggle on={showTable} onToggle={() => setShowTable((v) => !v)} />
      </View>
      {showTable ? (
        <DataRows title={title} labels={labels} series={[{ name: title, values }]} format={format} />
      ) : (
        <View onLayout={onLayout} accessibilityLabel={title}>
          <Svg width={width} height={height}>
            <Line x1={0} x2={width} y1={pad.t + plotH} y2={pad.t + plotH} stroke={t.colors.separator} strokeWidth={1} />
            {values.map((v, i) => {
              const h = Math.max(v > 0 ? 3 : 0, (v / hi) * plotH);
              const bx = i * slot + (slot - barW) / 2;
              const by = pad.t + plotH - h;
              const r = Math.min(4, h, barW / 2);
              // Rounded top only: the data end; the baseline end stays square.
              const d = h <= 0 ? '' : `M${bx},${pad.t + plotH} L${bx},${by + r} Q${bx},${by} ${bx + r},${by} L${bx + barW - r},${by} Q${bx + barW},${by} ${bx + barW},${by + r} L${bx + barW},${pad.t + plotH} Z`;
              return <Path key={labels[i]} d={d} fill={fill} opacity={i === sel ? 1 : 0.55} />;
            })}
            {labels.map((l, i) =>
              i === 0 || i === labels.length - 1 || i === sel ? (
                <SvgText key={l} x={i * slot + slot / 2} y={height - 6} fill={t.colors.textSecondary} fontSize={10} textAnchor="middle">
                  {l}
                </SvgText>
              ) : null,
            )}
          </Svg>
          <View style={[StyleSheet.absoluteFill, styles.hitRow]}>
            {labels.map((l, i) => (
              <Pressable key={l} style={styles.hit} onPress={() => setSelected(i)} onHoverIn={() => setSelected(i)} accessibilityRole="button" accessibilityLabel={`${l}: ${format(values[i] ?? 0)}`} />
            ))}
          </View>
        </View>
      )}
    </View>
  );
}

/** Horizontal comparison bars with value labels and an optional target tick. */
export function HBarList({
  rows,
  format,
  max = 1,
  target,
}: {
  rows: readonly { label: string; value: number; sublabel?: string; flag?: ReactNode }[];
  format: (v: number) => string;
  max?: number;
  target?: number;
}) {
  const t = useTheme();
  return (
    <View style={{ gap: t.space.md }}>
      {rows.map((r) => (
        <View key={r.label} style={{ gap: 4 }} accessible accessibilityLabel={`${r.label}: ${format(r.value)}`}>
          <View style={styles.hbarHead}>
            <Text variant="subhead" style={{ flex: 1 }} numberOfLines={1}>
              {r.label}
              {r.sublabel !== undefined && (
                <Text variant="caption" color="textTertiary">{`  ${r.sublabel}`}</Text>
              )}
            </Text>
            {r.flag}
            <Text variant="subhead" weight="600" tabular>
              {format(r.value)}
            </Text>
          </View>
          <View style={[styles.hbarTrack, { backgroundColor: t.colors.fill }]}>
            <View style={[styles.hbarFill, { width: `${Math.max(0, Math.min(1, r.value / max)) * 100}%`, backgroundColor: t.colors.primary }]} />
            {target !== undefined && <View style={[styles.target, { left: `${(target / max) * 100}%`, backgroundColor: t.colors.text }]} />}
          </View>
        </View>
      ))}
    </View>
  );
}

/** Calendar heatmap (Mon–Sun columns), sequential single hue by rate. */
export function Heatmap({
  days,
  weekdayLabels,
  format,
  dateLabel,
}: {
  days: readonly { date: string; rate: number }[];
  weekdayLabels: readonly string[];
  format: (v: number) => string;
  dateLabel: (date: string) => string;
}) {
  const t = useTheme();
  const [selected, setSelected] = useState<string | null>(null);
  if (days.length === 0) return null;
  const first = new Date(`${days[0]?.date ?? ''}T00:00:00Z`).getUTCDay();
  const lead = (first + 6) % 7; // Monday-first
  // Fill gaps (weekends with nothing scheduled) by date.
  const byDate = new Map(days.map((d) => [d.date, d]));
  const start = Date.parse(`${days[0]?.date ?? ''}T00:00:00Z`);
  const end = Date.parse(`${days.at(-1)?.date ?? ''}T00:00:00Z`);
  const full: ({ date: string; rate: number } | null)[] = [...Array<null>(lead).fill(null)];
  for (let ms = start; ms <= end; ms += 86_400_000) {
    const key = new Date(ms).toISOString().slice(0, 10);
    full.push(byDate.get(key) ?? { date: key, rate: Number.NaN });
  }
  const sel = selected !== null ? byDate.get(selected) : undefined;
  return (
    <View style={{ gap: t.space.sm }}>
      <Text variant="footnote" color="textSecondary" accessibilityLiveRegion="polite">
        {sel !== undefined ? `${dateLabel(sel.date)} · ${format(sel.rate)}` : ' '}
      </Text>
      <View style={styles.heatGrid}>
        {weekdayLabels.map((w, i) => (
          <View key={`w${i}`} style={styles.heatCell}>
            <Text variant="caption" color="textTertiary">
              {w}
            </Text>
          </View>
        ))}
        {full.map((c, i) => {
          if (c === null) return <View key={`b${i}`} style={styles.heatCell} />;
          const empty = Number.isNaN(c.rate);
          // Sequential: light→dark of ONE hue; 85%→100% mapped to 0.2→1 opacity.
          const strength = empty ? 0 : Math.max(0.15, Math.min(1, (c.rate - 0.8) / 0.2));
          return (
            <Pressable
              key={c.date}
              style={styles.heatCell}
              onPress={() => !empty && setSelected(c.date)}
              onHoverIn={() => !empty && setSelected(c.date)}
              accessibilityLabel={empty ? dateLabel(c.date) : `${dateLabel(c.date)}: ${format(c.rate)}`}
            >
              <View style={[styles.heatSquare, { backgroundColor: empty ? t.colors.fill : t.colors.primary, opacity: empty ? 0.5 : strength, borderWidth: selected === c.date ? 2 : 0, borderColor: t.colors.text }]} />
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

/** Headline KPI with change vs the previous period (icon + sign, not color alone). */
export function KpiTile({
  label,
  value,
  delta,
  better,
  hint,
}: {
  label: string;
  value: string;
  /** Formatted change, e.g. "+1.2 pts"; omitted when not comparable. */
  delta?: { text: string; direction: 'up' | 'down' | 'flat' };
  /** Which direction is good for this metric. */
  better?: 'up' | 'down';
  hint?: string;
}) {
  const t = useTheme();
  const good = delta !== undefined && better !== undefined && delta.direction !== 'flat' ? delta.direction === better : undefined;
  const color = good === undefined ? t.colors.textSecondary : good ? t.colors.success : t.colors.danger;
  return (
    <View
      style={[styles.kpi, { backgroundColor: t.colors.surface, borderRadius: t.shape.card }]}
      accessible
      accessibilityLabel={`${label}: ${value}${delta !== undefined ? `, ${delta.text}` : ''}`}
    >
      <Text variant="footnote" color="textSecondary" numberOfLines={1}>
        {label}
      </Text>
      <Text variant="title" tabular numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      {delta !== undefined && (
        <View style={styles.delta}>
          <Icon name={delta.direction === 'up' ? 'arrowUp' : delta.direction === 'down' ? 'arrowDown' : 'sort'} size={12} color={color} />
          <Text variant="caption" weight="600" style={{ color }}>
            {delta.text}
          </Text>
        </View>
      )}
      {hint !== undefined && (
        <Text variant="caption" color="textTertiary" numberOfLines={2}>
          {hint}
        </Text>
      )}
    </View>
  );
}

function TableToggle({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  const t = useTheme();
  const { t: tr } = useI18n();
  return (
    <Touchable onPress={onToggle} feedback="none" hitSlop={8} accessibilityRole="switch" accessibilityState={{ checked: on }} accessibilityLabel={tr('reports.tableView')}>
      <View style={[styles.toggle, { backgroundColor: on ? t.colors.tonal : 'transparent', borderColor: t.colors.outline }]}>
        <Icon name="list" size={12} color={on ? t.colors.onTonal : t.colors.textSecondary} />
      </View>
    </Touchable>
  );
}

function DataRows({ labels, series, format, title }: { labels: readonly string[]; series: readonly Series[]; format: (v: number) => string; title: string }) {
  const t = useTheme();
  return (
    <View accessibilityLabel={title}>
      <View style={[styles.tableRow, { borderBottomColor: t.colors.separator }]}>
        <Text variant="caption" weight="700" color="textSecondary" style={{ flex: 1.4 }}>
          {' '}
        </Text>
        {series.map((s) => (
          <Text key={s.name} variant="caption" weight="700" color="textSecondary" style={styles.tableCell} numberOfLines={1}>
            {s.name}
          </Text>
        ))}
      </View>
      {labels.map((l, i) => (
        <View key={l} style={[styles.tableRow, { borderBottomColor: t.colors.separator }]}>
          <Text variant="footnote" style={{ flex: 1.4 }}>
            {l}
          </Text>
          {series.map((s) => (
            <Text key={s.name} variant="footnote" tabular style={styles.tableCell}>
              {format(s.values[i] ?? 0)}
            </Text>
          ))}
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  legendRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  legend: { flexDirection: 'row', flexWrap: 'wrap', gap: 12, flex: 1 },
  legendItem: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  legendSwatch: { width: 12, height: 3, borderRadius: 2 },
  readout: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, alignItems: 'baseline' },
  hitRow: { flexDirection: 'row' },
  hit: { flex: 1 },
  hbarHead: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  hbarTrack: { height: 8, borderRadius: 4, overflow: 'visible' },
  hbarFill: { height: 8, borderRadius: 4 },
  target: { position: 'absolute', top: -3, width: 2, height: 14, borderRadius: 1 },
  heatGrid: { flexDirection: 'row', flexWrap: 'wrap' },
  heatCell: { width: `${100 / 7}%`, aspectRatio: 1.6, alignItems: 'center', justifyContent: 'center', padding: 2 },
  heatSquare: { width: '100%', height: '100%', borderRadius: 4 },
  kpi: { padding: 14, gap: 2, flexGrow: 1, flexBasis: '45%', minWidth: 150 },
  delta: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  toggle: { width: 28, height: 22, borderRadius: 6, borderWidth: 1, alignItems: 'center', justifyContent: 'center' },
  tableRow: { flexDirection: 'row', paddingVertical: 6, borderBottomWidth: StyleSheet.hairlineWidth, gap: 8 },
  tableCell: { flex: 1, textAlign: 'right' },
});
