import type { SortSpec } from '@nforce/core';
import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { useTheme } from '@/design/theme';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export interface Column<T, K extends string> {
  readonly key: string;
  readonly title: string;
  /** Relative width (flex). */
  readonly flex: number;
  readonly align?: 'left' | 'right';
  /** When set, the header sorts by this key. */
  readonly sortKey?: K;
  readonly render: (row: T) => ReactNode;
}

/**
 * Desktop data table with sortable, keyboard/screen-reader accessible column
 * headers. Clicking the active header flips the direction.
 */
export function DataTable<T, K extends string>({
  columns,
  rows,
  rowKey,
  sort,
  onSort,
  onRowPress,
  rowLabel,
}: {
  columns: readonly Column<T, K>[];
  rows: readonly T[];
  rowKey: (row: T) => string;
  sort: SortSpec<K>;
  onSort: (s: SortSpec<K>) => void;
  onRowPress?: (row: T) => void;
  rowLabel?: (row: T) => string;
}) {
  const t = useTheme();
  return (
    <View style={{ backgroundColor: t.colors.surface, borderRadius: t.shape.card, overflow: 'hidden' }} accessibilityRole="list">
      <View style={[styles.row, styles.header, { borderBottomColor: t.colors.separator, backgroundColor: t.colors.fill }]}>
        {columns.map((c) => {
          const active = c.sortKey !== undefined && c.sortKey === sort.key;
          const content = (
            <View style={[styles.cellInner, c.align === 'right' && styles.right]}>
              <Text variant="caption" weight="700" color={active ? 'primary' : 'textSecondary'} style={{ textTransform: 'uppercase', letterSpacing: 0.5 }} numberOfLines={1}>
                {c.title}
              </Text>
              {active && <Icon name={sort.direction === 'asc' ? 'arrowUp' : 'arrowDown'} size={12} color={t.colors.primary} />}
            </View>
          );
          return (
            <View key={c.key} style={[styles.cell, { flex: c.flex }]}>
              {c.sortKey === undefined ? (
                content
              ) : (
                <Touchable
                  feedback="none"
                  haptic="selection"
                  accessibilityRole="button"
                  accessibilityLabel={`${c.title}${active ? `, ${sort.direction === 'asc' ? '↑' : '↓'}` : ''}`}
                  onPress={() => {
                    const key = c.sortKey as K;
                    onSort(active ? { key, direction: sort.direction === 'asc' ? 'desc' : 'asc' } : { key, direction: 'asc' });
                  }}
                >
                  {content}
                </Touchable>
              )}
            </View>
          );
        })}
      </View>
      {rows.map((row, i) => {
        const body = (
          <View style={[styles.row, i < rows.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }]}>
            {columns.map((c) => (
              <View key={c.key} style={[styles.cell, { flex: c.flex }, c.align === 'right' && styles.right]}>
                {c.render(row)}
              </View>
            ))}
          </View>
        );
        return onRowPress === undefined ? (
          <View key={rowKey(row)}>{body}</View>
        ) : (
          <Touchable key={rowKey(row)} onPress={() => onRowPress(row)} feedback="highlight" accessibilityLabel={rowLabel?.(row)}>
            {body}
          </Touchable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12, minHeight: 56 },
  header: { minHeight: 40, borderBottomWidth: StyleSheet.hairlineWidth },
  cell: { paddingHorizontal: 8, justifyContent: 'center' },
  cellInner: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  right: { alignItems: 'flex-end', justifyContent: 'flex-end' },
});
