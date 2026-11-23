import {
  OPERATORS,
  VALUELESS,
  accessorsFor,
  activeConditionCount,
  applyConditions,
  formatDuration,
  isComplete,
  newCondition,
  queryList,
  type Condition,
  type FieldDef,
  type MatchMode,
  type Operator,
  type SortSpec,
} from '@nforce/core';
import { useMemo, useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useTheme } from '@/design/theme';
import { useI18n, type I18n } from '@/i18n';
import { saveListView, useListViewState, type ListView } from '@/state/listViews';
import { Button } from './Button';
import { Chip, SegmentedControl } from './Controls';
import { Icon } from './Icon';
import { FilterChips, SearchField, SortButton, type FilterOption } from './ListToolbar';
import { Text } from './Text';
import { Touchable } from './Touchable';

/**
 * Sorting and custom filtering for every list and table.
 *
 * A screen declares its fields once (label, kind, how to read the value). From
 * that, people get: search, sorting by any field (or by tapping a column), an
 * optional quick filter, and a filter builder where they add their own
 * conditions and match all or any. Each screen remembers its view.
 */

export interface QuickFilter<T> {
  readonly value: string;
  readonly label: string;
  readonly test?: (item: T) => boolean;
}

export interface ListViewConfig<T> {
  /** Unique per screen/list; the saved view is stored under it. */
  readonly id: string;
  readonly fields: readonly FieldDef<T>[];
  readonly defaultSort: SortSpec;
  /** Text searched by the search box (omit to hide search). */
  readonly searchText?: (item: T) => readonly (string | undefined)[];
  readonly quickFilters?: readonly QuickFilter<T>[];
}

export interface ListViewState<T> {
  readonly config: ListViewConfig<T>;
  readonly view: ListView;
  readonly search: string;
  readonly setSearch: (s: string) => void;
  readonly sort: SortSpec;
  readonly setSort: (s: SortSpec) => void;
  readonly setConditions: (c: readonly Condition[], match?: MatchMode) => void;
  readonly quick: string;
  readonly setQuick: (q: string) => void;
  /** Quick filter → conditions → search → sort. */
  readonly apply: (items: readonly T[]) => T[];
  readonly activeCount: number;
}

export function useListView<T>(config: ListViewConfig<T>): ListViewState<T> {
  const view = useListViewState(config.id);
  const [search, setSearch] = useState('');
  const sortable = config.fields.filter((f) => f.sortable !== false).map((f) => f.key);
  const sort = view.sort !== undefined && sortable.includes(view.sort.key) ? view.sort : config.defaultSort;
  const quickValues = (config.quickFilters ?? []).map((q) => q.value);
  const quick = view.quick !== undefined && quickValues.includes(view.quick) ? view.quick : (quickValues[0] ?? '');
  const save = (patch: Partial<ListView>) => saveListView(config.id, { ...view, ...patch });
  const accessors = useMemo(() => accessorsFor(config.fields), [config.fields]);

  const apply = (items: readonly T[]): T[] => {
    const q = config.quickFilters?.find((x) => x.value === quick)?.test;
    const filtered = applyConditions(q !== undefined ? items.filter(q) : items, config.fields, view.conditions, view.match);
    return queryList(filtered, {
      ...(config.searchText !== undefined ? { search: { text: search, fields: config.searchText } } : {}),
      sort,
      accessors,
    });
  };

  return {
    config,
    view,
    search,
    setSearch,
    sort,
    setSort: (s) => save({ sort: s }),
    setConditions: (conditions, match) => save({ conditions, ...(match !== undefined ? { match } : {}) }),
    quick,
    setQuick: (q) => save({ quick: q }),
    apply,
    activeCount: activeConditionCount(config.fields, view.conditions),
  };
}

// ------------------------------------------------------------------ toolbar

/** Search, quick filter, filter builder, sort and active filter chips. */
export function ListControls<T>({
  state,
  searchPlaceholder,
  resultCount,
  quickCounts,
}: {
  state: ListViewState<T>;
  searchPlaceholder?: string;
  resultCount?: number;
  /** Optional counts shown on quick filter chips. */
  quickCounts?: Readonly<Record<string, number>>;
}) {
  const t = useTheme();
  const i18n = useI18n();
  const [open, setOpen] = useState(false);
  const { config, view } = state;
  const sortOptions = config.fields
    .filter((f) => f.sortable !== false)
    .map((f) => ({ key: f.key, label: f.label, defaultDirection: f.kind === 'text' || f.kind === 'choice' ? ('asc' as const) : ('desc' as const) }));
  const quick: FilterOption<string>[] = (config.quickFilters ?? []).map((q) => ({ value: q.value, label: q.label, ...(quickCounts?.[q.value] !== undefined ? { count: quickCounts[q.value] } : {}) }));
  const active = view.conditions.filter((c) => isComplete(config.fields.find((f) => f.key === c.field) as FieldDef<unknown> | undefined, c));

  return (
    <View style={{ gap: t.space.md }}>
      {config.searchText !== undefined && <SearchField value={state.search} onChange={state.setSearch} placeholder={searchPlaceholder ?? i18n.t('list.search')} />}
      {quick.length > 0 && <FilterChips options={quick} value={state.quick} onChange={state.setQuick} />}
      <View style={styles.rowBetween}>
        <Text variant="footnote" color="textSecondary" accessibilityLiveRegion="polite" style={{ flexShrink: 1 }}>
          {resultCount !== undefined ? i18n.plural('list.results', resultCount) : ''}
        </Text>
        <View style={styles.row}>
          <Touchable
            onPress={() => setOpen(true)}
            haptic="selection"
            accessibilityRole="button"
            accessibilityLabel={`${i18n.t('list.filter')}${state.activeCount > 0 ? `, ${state.activeCount}` : ''}`}
            style={[styles.pill, { backgroundColor: state.activeCount > 0 ? t.colors.primary : t.colors.tonal }]}
          >
            <Icon name="list" size={15} color={state.activeCount > 0 ? t.colors.onPrimary : t.colors.onTonal} />
            <Text variant="footnote" weight="600" style={{ color: state.activeCount > 0 ? t.colors.onPrimary : t.colors.onTonal }}>
              {state.activeCount > 0 ? `${i18n.t('list.filter')} · ${state.activeCount}` : i18n.t('list.filter')}
            </Text>
          </Touchable>
          <SortButton options={sortOptions} value={state.sort} onChange={state.setSort} />
        </View>
      </View>
      {active.length > 0 && (
        <View style={styles.wrap}>
          {active.map((c) => (
            <View key={c.id} style={[styles.activeChip, { backgroundColor: t.colors.primaryContainer, borderRadius: 999 }]}>
              <Touchable onPress={() => setOpen(true)} feedback="none" accessibilityRole="button" accessibilityLabel={describe(config.fields, c, i18n)}>
                <Text variant="footnote" weight="600" style={{ color: t.colors.onPrimaryContainer }} numberOfLines={1}>
                  {describe(config.fields, c, i18n)}
                </Text>
              </Touchable>
              <Touchable
                onPress={() => state.setConditions(view.conditions.filter((x) => x.id !== c.id))}
                feedback="none"
                hitSlop={8}
                accessibilityRole="button"
                accessibilityLabel={i18n.t('list.removeCondition')}
              >
                <Icon name="close" size={13} color={t.colors.onPrimaryContainer} />
              </Touchable>
            </View>
          ))}
          {active.length > 1 && (
            <Text variant="caption" color="textSecondary" style={{ alignSelf: 'center' }}>
              {i18n.t(view.match === 'all' ? 'list.matchingAll' : 'list.matchingAny')}
            </Text>
          )}
          <Button title={i18n.t('list.clearFilters')} variant="plain" size="small" onPress={() => state.setConditions([])} />
        </View>
      )}
      {open && <FilterSheet state={state} onClose={() => setOpen(false)} />}
    </View>
  );
}

// ------------------------------------------------------------------ builder

let seq = 0;
const nextId = () => `c${Date.now().toString(36)}${(++seq).toString(36)}`;

function FilterSheet<T>({ state, onClose }: { state: ListViewState<T>; onClose: () => void }) {
  const t = useTheme();
  const i18n = useI18n();
  const insets = useSafeAreaInsets();
  const { fields } = state.config;
  const [draft, setDraft] = useState<readonly Condition[]>(state.view.conditions.length > 0 ? state.view.conditions : []);
  const [match, setMatch] = useState<MatchMode>(state.view.match);
  const update = (id: string, patch: Partial<Condition>) => setDraft((d) => d.map((c) => (c.id === id ? ({ ...c, ...patch } as Condition) : c)));
  const add = () => {
    const field = fields[0];
    if (field !== undefined) setDraft((d) => [...d, newCondition(field, nextId())]);
  };
  const done = () => {
    state.setConditions(draft, match);
    onClose();
  };

  return (
    <Modal visible transparent animationType="fade" onRequestClose={done} statusBarTranslucent>
      <Pressable style={[styles.scrim, { backgroundColor: t.colors.scrim }]} onPress={done} accessibilityLabel={i18n.t('common.close')}>
        <Pressable style={[styles.sheet, { backgroundColor: t.colors.surfaceRaised, borderRadius: t.shape.sheet, paddingBottom: insets.bottom + 16 }]} accessibilityViewIsModal>
          <View style={[styles.rowBetween, { padding: t.space.lg, paddingBottom: t.space.sm }]}>
            <Text variant="headline" accessibilityRole="header">
              {i18n.t('list.filters')}
            </Text>
            <Button title={i18n.t('list.done')} size="small" onPress={done} />
          </View>
          <ScrollView style={{ maxHeight: 560 }} contentContainerStyle={{ padding: t.space.lg, paddingTop: 0, gap: t.space.lg }} keyboardShouldPersistTaps="handled">
            {draft.length > 1 && (
              <SegmentedControl
                segments={[
                  { value: 'all', label: i18n.t('list.matchAll') },
                  { value: 'any', label: i18n.t('list.matchAny') },
                ]}
                value={match}
                onChange={setMatch}
              />
            )}
            {draft.length === 0 && (
              <Text variant="subhead" color="textSecondary">
                {i18n.t('list.noConditions')}
              </Text>
            )}
            {draft.map((c, index) => {
              const field = fields.find((f) => f.key === c.field) ?? fields[0];
              if (field === undefined) return null;
              return (
                <View key={c.id} style={[styles.condition, { backgroundColor: t.colors.fill, borderRadius: t.shape.control, gap: t.space.sm }]}>
                  <View style={styles.rowBetween}>
                    <Text variant="footnote" weight="700" color="textSecondary">
                      {index === 0 ? i18n.t('list.where') : i18n.t(match === 'all' ? 'list.and' : 'list.or')}
                    </Text>
                    <Touchable onPress={() => setDraft((d) => d.filter((x) => x.id !== c.id))} hitSlop={8} accessibilityRole="button" accessibilityLabel={i18n.t('list.removeCondition')}>
                      <Icon name="close" size={16} color={t.colors.textSecondary} />
                    </Touchable>
                  </View>
                  <ChipRow
                    label={i18n.t('list.field')}
                    options={fields.map((f) => ({ value: f.key, label: f.label }))}
                    value={[field.key]}
                    onToggle={(key) => {
                      const next = fields.find((f) => f.key === key);
                      if (next !== undefined && next.key !== c.field) setDraft((d) => d.map((x) => (x.id === c.id ? newCondition(next, c.id) : x)));
                    }}
                  />
                  <ChipRow
                    label={i18n.t('list.condition')}
                    options={OPERATORS[field.kind].map((op) => ({ value: op, label: opLabel(field.kind, op, i18n) }))}
                    value={[c.op]}
                    onToggle={(op) => update(c.id, { op: op as Operator })}
                  />
                  {!VALUELESS.has(c.op) && <ValueEditor field={field} condition={c} onChange={(patch) => update(c.id, patch)} />}
                </View>
              );
            })}
            <View style={styles.row}>
              <Button title={i18n.t('list.addCondition')} icon="add" variant="tonal" size="small" onPress={add} />
              {draft.length > 0 && <Button title={i18n.t('list.clearFilters')} variant="plain" size="small" onPress={() => setDraft([])} />}
            </View>
          </ScrollView>
        </Pressable>
      </Pressable>
    </Modal>
  );
}

function ChipRow({ label, options, value, onToggle }: { label: string; options: readonly { value: string; label: string }[]; value: readonly string[]; onToggle: (v: string) => void }) {
  return (
    <View style={{ gap: 6 }}>
      <Text variant="caption" color="textSecondary">
        {label}
      </Text>
      <View style={styles.wrap}>
        {options.map((o) => (
          <Chip key={o.value} label={o.label} selected={value.includes(o.value)} onPress={() => onToggle(o.value)} />
        ))}
      </View>
    </View>
  );
}

/** Value input by field kind. Durations are typed in hours, percents in %. */
function ValueEditor<T>({ field, condition: c, onChange }: { field: FieldDef<T>; condition: Condition; onChange: (patch: Partial<Condition>) => void }) {
  const t = useTheme();
  const i18n = useI18n();
  if (field.kind === 'choice') {
    const chosen = Array.isArray(c.value) ? (c.value as readonly string[]) : [];
    return (
      <ChipRow
        label={i18n.t('list.value')}
        options={field.options ?? []}
        value={chosen}
        onToggle={(v) => onChange({ value: chosen.includes(v) ? chosen.filter((x) => x !== v) : [...chosen, v] })}
      />
    );
  }
  const toInput = (v: unknown): string => {
    if (v === undefined || v === null) return '';
    if (field.kind === 'duration' && typeof v === 'number') return String(Math.round((v / 60) * 100) / 100);
    if (field.kind === 'percent' && typeof v === 'number') return String(Math.round(v * 1000) / 10);
    return String(v);
  };
  const fromInput = (s: string): string | number | undefined => {
    const text = s.trim();
    if (text === '') return undefined;
    if (field.kind === 'text' || field.kind === 'date') return s;
    const hm = /^(\d+):(\d{1,2})$/.exec(text);
    const n = hm !== null ? Number(hm[1]) + Number(hm[2]) / 60 : Number(text.replace(',', '.'));
    if (!Number.isFinite(n)) return undefined;
    return field.kind === 'duration' ? Math.round(n * 60) : field.kind === 'percent' ? n / 100 : n;
  };
  const unit = field.kind === 'duration' ? i18n.t('list.unit.hours') : field.kind === 'percent' ? '%' : field.kind === 'date' ? 'YYYY-MM-DD' : '';
  const input = (key: 'value' | 'value2', placeholder: string) => (
    <TextInput
      defaultValue={toInput(c[key])}
      onChangeText={(s) => onChange({ [key]: fromInput(s) } as Partial<Condition>)}
      placeholder={placeholder}
      placeholderTextColor={t.colors.textTertiary}
      keyboardType={field.kind === 'text' || field.kind === 'date' ? 'default' : 'decimal-pad'}
      autoCapitalize="none"
      accessibilityLabel={`${field.label} ${placeholder}`}
      style={[t.type.body, styles.input, { color: t.colors.text, backgroundColor: t.colors.surface, borderRadius: t.shape.control }]}
    />
  );
  return (
    <View style={{ gap: 6 }}>
      <Text variant="caption" color="textSecondary">
        {i18n.t('list.value')}
        {unit !== '' ? ` (${unit})` : ''}
      </Text>
      <View style={styles.row}>
        <View style={{ flex: 1 }}>{input('value', unit || i18n.t('list.value'))}</View>
        {c.op === 'between' && (
          <>
            <Text variant="footnote" color="textSecondary">
              {i18n.t('list.and')}
            </Text>
            <View style={{ flex: 1 }}>{input('value2', unit || i18n.t('list.value'))}</View>
          </>
        )}
      </View>
    </View>
  );
}

// ------------------------------------------------------------------ text

function opLabel(kind: FieldDef<unknown>['kind'], op: Operator, i18n: I18n): string {
  if (kind === 'date' && op === 'between') return i18n.t('list.op.between');
  return i18n.t(`list.op.${op}`);
}

function valueText<T>(field: FieldDef<T>, v: Condition['value'], i18n: I18n): string {
  if (v === undefined) return '';
  if (Array.isArray(v)) return v.map((x) => field.options?.find((o) => o.value === x)?.label ?? x).join(', ');
  if (field.kind === 'duration' && typeof v === 'number') return formatDuration(v);
  if (field.kind === 'percent' && typeof v === 'number') return `${Math.round(v * 1000) / 10}%`;
  if (field.kind === 'date' && typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) return i18n.date(v as never, { month: 'short', day: 'numeric', year: 'numeric' });
  return String(v);
}

/** "Overtime > 2h", "Status is any of Pending, Returned". */
export function describe<T>(fields: readonly FieldDef<T>[], c: Condition, i18n: I18n): string {
  const field = fields.find((f) => f.key === c.field);
  if (field === undefined) return '';
  const op = opLabel(field.kind, c.op, i18n);
  if (VALUELESS.has(c.op)) return `${field.label} ${op}`;
  const a = valueText(field, c.value, i18n);
  return c.op === 'between' ? `${field.label} ${op} ${a} – ${valueText(field, c.value2, i18n)}` : `${field.label} ${op} ${a}`;
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowBetween: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' },
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, alignItems: 'center' },
  pill: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, paddingVertical: 7, borderRadius: 999 },
  activeChip: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingLeft: 12, paddingRight: 8, paddingVertical: 6, maxWidth: '100%' },
  scrim: { flex: 1, justifyContent: 'flex-end', alignItems: 'center' },
  sheet: { width: '100%', maxWidth: 620 },
  condition: { padding: 12 },
  input: { minHeight: 44, paddingHorizontal: 12, paddingVertical: 8 },
});
