import type { SortSpec } from '@nforce/core';
import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';

import { useTheme } from '@/design/theme';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export interface GridColumn<T> {
  readonly key: string;
  readonly title: string;
  /** Minimum width in points. Columns grow to fill wide screens. */
  readonly width: number;
  readonly align?: 'left' | 'right' | 'center';
  readonly render: (row: T) => ReactNode;
  /** Optional cell in the totals row. */
  readonly footer?: ReactNode;
  /** Field key this column sorts by when its header is tapped. */
  readonly sortKey?: string;
}

/**
 * A dense, spreadsheet-like table for timesheets and rosters. Columns keep a
 * minimum width; on narrow screens the table scrolls horizontally instead of
 * squeezing numbers. Rows can be tinted (e.g. rest days, today) and pressed.
 */
export function GridTable<T>({
  columns,
  rows,
  rowKey,
  onRowPress,
  rowLabel,
  rowTint,
  showFooter = false,
  caption,
  emptyLabel,
  style,
  sort,
  onSort,
}: {
  columns: readonly GridColumn<T>[];
  rows: readonly T[];
  rowKey: (row: T) => string;
  onRowPress?: (row: T) => void;
  rowLabel?: (row: T) => string;
  rowTint?: (row: T) => string | undefined;
  showFooter?: boolean;
  /** Accessible summary of the table, read before the rows. */
  caption?: string;
  emptyLabel?: string;
  style?: StyleProp<ViewStyle>;
  /** Current sort; headers with a `sortKey` become sort buttons. */
  sort?: SortSpec;
  onSort?: (s: SortSpec) => void;
}) {
  const t = useTheme();
  const minWidth = columns.reduce((n, c) => n + c.width, 0);
  const cell = (c: GridColumn<T>) => [styles.cell, { flexGrow: c.width, flexBasis: c.width, minWidth: c.width }, c.align === 'right' ? styles.right : c.align === 'center' ? styles.center : undefined];

  const header = (
    <View style={[styles.row, styles.header, { backgroundColor: t.colors.fill, borderBottomColor: t.colors.separator }]} accessibilityRole="header">
      {columns.map((c) => {
        const active = c.sortKey !== undefined && sort?.key === c.sortKey;
        const label = (
          <View style={[styles.headerInner, c.align === 'right' && styles.headerRight]}>
            <Text variant="caption" weight="700" color={active ? 'primary' : 'textSecondary'} numberOfLines={1} style={styles.headerText}>
              {c.title}
            </Text>
            {active && <Icon name={sort?.direction === 'asc' ? 'arrowUp' : 'arrowDown'} size={11} color={t.colors.primary} />}
          </View>
        );
        return (
          <View key={c.key} style={cell(c)}>
            {c.sortKey !== undefined && onSort !== undefined ? (
              <Touchable
                feedback="none"
                haptic="selection"
                accessibilityRole="button"
                accessibilityLabel={`${c.title}${active ? `, ${sort?.direction === 'asc' ? '↑' : '↓'}` : ''}`}
                onPress={() => {
                  const key = c.sortKey as string;
                  onSort(active && sort !== undefined ? { key, direction: sort.direction === 'asc' ? 'desc' : 'asc' } : { key, direction: c.align === 'right' ? 'desc' : 'asc' });
                }}
              >
                {label}
              </Touchable>
            ) : (
              label
            )}
          </View>
        );
      })}
    </View>
  );

  const body = rows.map((row, i) => {
    const tint = rowTint?.(row);
    const content = (
      <View
        style={[
          styles.row,
          tint !== undefined && { backgroundColor: tint },
          (i < rows.length - 1 || showFooter) && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
        ]}
      >
        {columns.map((c) => (
          <View key={c.key} style={cell(c)}>
            {c.render(row)}
          </View>
        ))}
      </View>
    );
    return onRowPress === undefined ? (
      <View key={rowKey(row)} accessible={rowLabel !== undefined} accessibilityLabel={rowLabel?.(row)}>
        {content}
      </View>
    ) : (
      <Touchable key={rowKey(row)} onPress={() => onRowPress(row)} feedback="highlight" accessibilityRole="button" accessibilityLabel={rowLabel?.(row)}>
        {content}
      </Touchable>
    );
  });

  const footer = showFooter ? (
    <View style={[styles.row, styles.footer, { backgroundColor: t.colors.fill }]}>
      {columns.map((c) => (
        <View key={c.key} style={cell(c)}>
          {c.footer ?? null}
        </View>
      ))}
    </View>
  ) : null;

  return (
    <View style={[{ backgroundColor: t.colors.surface, borderRadius: t.shape.card, overflow: 'hidden' }, style]} accessibilityLabel={caption}>
      <ScrollView horizontal showsHorizontalScrollIndicator bounces={false} contentContainerStyle={{ flexGrow: 1 }}>
        <View style={{ minWidth, flexGrow: 1 }}>
          {header}
          {rows.length === 0 && emptyLabel !== undefined ? (
            <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
              {emptyLabel}
            </Text>
          ) : (
            body
          )}
          {footer}
        </View>
      </ScrollView>
    </View>
  );
}

/** Numeric cell text: tabular figures, muted when zero. */
export function NumCell({ value, strong = false, tone }: { value: string; strong?: boolean; tone?: string }) {
  const zero = value === '0m' || value === '—' || value === '';
  return (
    <Text variant="subhead" tabular weight={strong ? '700' : '500'} color={zero ? 'textTertiary' : undefined} style={tone !== undefined && !zero ? { color: tone } : undefined} numberOfLines={1}>
      {value === '0m' || value === '' ? '—' : value}
    </Text>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', minHeight: 48, paddingHorizontal: 6 },
  header: { minHeight: 38, borderBottomWidth: StyleSheet.hairlineWidth },
  footer: { minHeight: 44 },
  headerText: { textTransform: 'uppercase', letterSpacing: 0.4 },
  headerInner: { flexDirection: 'row', alignItems: 'center', gap: 3 },
  headerRight: { justifyContent: 'flex-end' },
  cell: { paddingHorizontal: 8, paddingVertical: 6, justifyContent: 'center' },
  right: { alignItems: 'flex-end' },
  center: { alignItems: 'center' },
});
