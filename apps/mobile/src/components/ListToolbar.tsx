import type { SortDirection, SortSpec } from '@nforce/core';
import { useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { Chip } from './Controls';
import { Icon } from './Icon';
import { Text } from './Text';
import { Touchable } from './Touchable';

export interface FilterOption<V extends string> {
  readonly value: V;
  readonly label: string;
  readonly count?: number;
}

export interface SortOption<K extends string> {
  readonly key: K;
  readonly label: string;
  /** Direction used when this option is first chosen. */
  readonly defaultDirection?: SortDirection;
}

/** Native-feeling search field (iOS search bar / M3 search). */
export function SearchField({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }) {
  const t = useTheme();
  const { t: tr } = useI18n();
  return (
    <View
      style={[
        styles.search,
        {
          backgroundColor: t.flavor === 'ios' ? t.colors.fill : t.colors.surface,
          borderRadius: t.flavor === 'ios' ? 12 : 28,
          minHeight: t.flavor === 'ios' ? 38 : 48,
        },
      ]}
    >
      <Icon name="search" size={17} color={t.colors.textSecondary} />
      <TextInput
        value={value}
        onChangeText={onChange}
        placeholder={placeholder}
        placeholderTextColor={t.colors.textSecondary}
        accessibilityLabel={placeholder}
        returnKeyType="search"
        autoCorrect={false}
        clearButtonMode="while-editing"
        style={[t.type.body, styles.searchInput, { color: t.colors.text }]}
      />
      {value.length > 0 && (
        <Touchable onPress={() => onChange('')} feedback="none" hitSlop={10} accessibilityLabel={tr('list.clearSearch')}>
          <Icon name="close" size={16} color={t.colors.textSecondary} />
        </Touchable>
      )}
    </View>
  );
}

/** Horizontal single-select filter chips with optional counts. */
export function FilterChips<V extends string>({
  options,
  value,
  onChange,
}: {
  options: readonly FilterOption<V>[];
  value: V;
  onChange: (v: V) => void;
}) {
  const t = useTheme();
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginHorizontal: -t.space.lg, flexGrow: 0 }} contentContainerStyle={{ gap: t.space.sm, paddingHorizontal: t.space.lg }}>
      {options.map((o) => (
        <Chip key={o.value} label={o.count !== undefined ? `${o.label} · ${o.count}` : o.label} selected={o.value === value} onPress={() => onChange(o.value)} />
      ))}
    </ScrollView>
  );
}

/** Sort trigger + sheet. Picking the active option again flips the direction. */
export function SortButton<K extends string>({
  options,
  value,
  onChange,
}: {
  options: readonly SortOption<K>[];
  value: SortSpec<K>;
  onChange: (v: SortSpec<K>) => void;
}) {
  const t = useTheme();
  const { t: tr } = useI18n();
  const insets = useSafeAreaInsets();
  const [open, setOpen] = useState(false);
  const active = options.find((o) => o.key === value.key);
  const dirLabel = tr(value.direction === 'asc' ? 'list.ascending' : 'list.descending');

  const choose = (o: SortOption<K>) => {
    onChange(o.key === value.key ? { key: o.key, direction: value.direction === 'asc' ? 'desc' : 'asc' } : { key: o.key, direction: o.defaultDirection ?? 'asc' });
    setOpen(false);
  };

  return (
    <>
      <Touchable
        onPress={() => setOpen(true)}
        haptic="selection"
        accessibilityLabel={`${tr('list.sortBy')}: ${active?.label ?? ''}, ${dirLabel}`}
        style={[styles.sortButton, { borderRadius: 999, backgroundColor: t.colors.tonal }]}
      >
        <Icon name="sort" size={15} color={t.colors.onTonal} />
        <Text variant="footnote" weight="600" style={{ color: t.colors.onTonal }} numberOfLines={1}>
          {active?.label}
        </Text>
        <Icon name={value.direction === 'asc' ? 'arrowUp' : 'arrowDown'} size={13} color={t.colors.onTonal} />
      </Touchable>
      <Modal visible={open} transparent animationType="fade" onRequestClose={() => setOpen(false)} statusBarTranslucent>
        <Pressable style={[styles.scrim, { backgroundColor: t.colors.scrim }]} onPress={() => setOpen(false)} accessibilityLabel={tr('common.close')}>
          <Pressable
            style={[styles.sheet, { backgroundColor: t.colors.surfaceRaised, borderRadius: t.shape.sheet, paddingBottom: insets.bottom + 12 }]}
            accessibilityViewIsModal
          >
            <Text variant="headline" style={{ padding: t.space.lg }} accessibilityRole="header">
              {tr('list.sortBy')}
            </Text>
            {options.map((o) => {
              const selected = o.key === value.key;
              return (
                <Touchable
                  key={o.key}
                  onPress={() => choose(o)}
                  feedback="highlight"
                  accessibilityRole="radio"
                  accessibilityState={{ selected }}
                  style={[styles.sortRow, { paddingHorizontal: t.space.lg }]}
                >
                  <Text variant="body" style={{ flex: 1 }} weight={selected ? '600' : '400'}>
                    {o.label}
                  </Text>
                  {selected && (
                    <View style={styles.row}>
                      <Text variant="footnote" color="textSecondary">
                        {dirLabel}
                      </Text>
                      <Icon name={value.direction === 'asc' ? 'arrowUp' : 'arrowDown'} size={16} color={t.colors.primary} />
                    </View>
                  )}
                </Touchable>
              );
            })}
          </Pressable>
        </Pressable>
      </Modal>
    </>
  );
}

/** Search + filters + sort, laid out for phone or desktop. */
export function ListToolbar<V extends string, K extends string>({
  search,
  onSearch,
  searchPlaceholder,
  filters,
  filter,
  onFilter,
  sortOptions,
  sort,
  onSort,
  resultLabel,
}: {
  search: string;
  onSearch: (v: string) => void;
  searchPlaceholder: string;
  filters?: readonly FilterOption<V>[];
  filter?: V;
  onFilter?: (v: V) => void;
  sortOptions: readonly SortOption<K>[];
  sort: SortSpec<K>;
  onSort: (v: SortSpec<K>) => void;
  resultLabel?: string;
}) {
  const t = useTheme();
  return (
    <View style={{ gap: t.space.md }}>
      <SearchField value={search} onChange={onSearch} placeholder={searchPlaceholder} />
      {filters !== undefined && filter !== undefined && onFilter !== undefined && <FilterChips options={filters} value={filter} onChange={onFilter} />}
      <View style={styles.rowBetween}>
        <Text variant="footnote" color="textSecondary" accessibilityLiveRegion="polite">
          {resultLabel ?? ''}
        </Text>
        <SortButton options={sortOptions} value={sort} onChange={onSort} />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  search: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12 },
  searchInput: { flex: 1, paddingVertical: 8, outlineStyle: 'none' } as object,
  sortButton: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, paddingVertical: 7 },
  scrim: { flex: 1, justifyContent: 'flex-end', alignItems: 'center' },
  sheet: { width: '100%', maxWidth: 520, paddingTop: 4, marginBottom: 0 },
  sortRow: { flexDirection: 'row', alignItems: 'center', minHeight: 52, gap: 12 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
});
