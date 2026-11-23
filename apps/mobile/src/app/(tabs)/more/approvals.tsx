import { facetCounts, queryList, type SortSpec } from '@nforce/core';
import { useMemo, useState } from 'react';
import { AccessibilityInfo, StyleSheet, TextInput, View } from 'react-native';

import { Button } from '@/components/Button';
import { SegmentedControl } from '@/components/Controls';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { Icon } from '@/components/Icon';
import { ListToolbar, type FilterOption, type SortOption } from '@/components/ListToolbar';
import { describeRequest as describe } from '@/components/requestText';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useApprovals, useDecide, useSession } from '@/data/queries';
import type { ApprovalItem, ApprovalStepView, RequestKind } from '@/data/types';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n, type I18n } from '@/i18n';

const KIND_TONE: Readonly<Record<RequestKind, Tone>> = {
  timesheet: 'primary',
  leave: 'success',
  day_off: 'info',
  overtime: 'warning',
  correction: 'danger',
};
const KINDS: readonly RequestKind[] = ['leave', 'day_off', 'overtime', 'timesheet', 'correction'];

type Scope = 'mine' | 'all';
type KindFilter = 'all' | RequestKind;
type SortKey = 'newest' | 'requester' | 'kind' | 'starts';

export default function ApprovalsScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { columns } = useResponsive();
  const approvals = useApprovals();
  const [scope, setScope] = useState<Scope>('mine');
  const [kind, setKind] = useState<KindFilter>('all');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<SortSpec<SortKey>>({ key: 'newest', direction: 'desc' });

  const inScope = useMemo(
    () => (approvals.data ?? []).filter((a) => (scope === 'mine' ? a.canDecide : true)),
    [approvals.data, scope],
  );
  const counts = useMemo(() => facetCounts(inScope, (a) => a.kind), [inScope]);
  const rows = useMemo(
    () =>
      queryList(inScope, {
        filters: kind === 'all' ? [] : [(a) => a.kind === kind],
        search: { text: search, fields: (a) => [a.requester.name, a.teamName, i18n.t(`approvals.kind.${a.kind}`), describe(a, i18n).summary] },
        sort,
        locale: i18n.tag,
        accessors: {
          newest: (a) => a.submittedAt,
          requester: (a) => a.requester.name,
          kind: (a) => i18n.t(`approvals.kind.${a.kind}`),
          starts: (a) => ('start' in a.payload ? a.payload.start : 'date' in a.payload ? a.payload.date : 'periodStart' in a.payload ? a.payload.periodStart : undefined),
        },
      }),
    [inScope, kind, search, sort, i18n],
  );

  const filters: FilterOption<KindFilter>[] = [
    { value: 'all', label: i18n.t('list.all'), count: inScope.length },
    ...KINDS.filter((k) => (counts.get(k) ?? 0) > 0 || k === kind).map((k) => ({ value: k, label: i18n.t(`approvals.kind.${k}`), count: counts.get(k) ?? 0 })),
  ];
  const sortOptions: SortOption<SortKey>[] = [
    { key: 'newest', label: i18n.t('approvals.sort.submitted'), defaultDirection: 'desc' },
    { key: 'starts', label: i18n.t('approvals.sort.starts') },
    { key: 'requester', label: i18n.t('approvals.sort.requester') },
    { key: 'kind', label: i18n.t('approvals.sort.kind') },
  ];
  const mineCount = (approvals.data ?? []).filter((a) => a.canDecide).length;

  return (
    <Screen onRefresh={() => approvals.refetch()}>
      <SegmentedControl<Scope>
        segments={[
          { value: 'mine', label: `${i18n.t('approvals.scope.mine')} · ${mineCount}` },
          { value: 'all', label: i18n.t('approvals.scope.all') },
        ]}
        value={scope}
        onChange={setScope}
      />
      <ListToolbar
        search={search}
        onSearch={setSearch}
        searchPlaceholder={i18n.t('approvals.search')}
        filters={filters}
        filter={kind}
        onFilter={setKind}
        sortOptions={sortOptions}
        sort={sort}
        onSort={setSort}
        resultLabel={i18n.plural('list.results', rows.length)}
      />
      {approvals.isError ? (
        <ErrorState onRetry={() => void approvals.refetch()} message={errorMessage(approvals.error, i18n.t('common.errorBody'))} />
      ) : approvals.data === undefined ? (
        <LoadingBlock rows={3} height={170} />
      ) : rows.length === 0 ? (
        <EmptyState icon="checkCircle" title={i18n.t('approvals.emptyTitle')} body={i18n.t(scope === 'mine' ? 'approvals.emptyBody' : 'list.noMatches')} />
      ) : (
        <View style={[styles.grid, { gap: t.space.lg }]}>
          {rows.map((item) => (
            <View key={item.id} style={{ flexBasis: columns === 1 ? '100%' : columns === 2 ? '48%' : '31%', flexGrow: 1 }}>
              <ApprovalCard item={item} />
            </View>
          ))}
        </View>
      )}
    </Screen>
  );
}

function ChainStepper({ steps, i18n }: { steps: readonly ApprovalStepView[]; i18n: I18n }) {
  const t = useTheme();
  const color = (s: ApprovalStepView['status']) =>
    s === 'approved' ? t.colors.success : s === 'returned' ? t.colors.danger : s === 'pending' ? t.colors.warning : t.colors.textTertiary;
  return (
    <View style={{ gap: 6 }} accessibilityRole="list">
      {steps.map((s, i) => (
        <View key={`${s.level}-${i}`} style={styles.step} accessible accessibilityLabel={`${i18n.t(`approvals.level.${s.level}`)}: ${s.approver.name}, ${i18n.t(`approvals.step.${s.status}`)}`}>
          <View style={[styles.stepDot, { borderColor: color(s.status), backgroundColor: s.status === 'approved' ? color(s.status) : 'transparent' }]}>
            {s.status === 'approved' && <Icon name="check" size={10} color="#FFFFFF" weight="bold" />}
          </View>
          <Text variant="footnote" style={{ flex: 1 }} numberOfLines={1}>
            <Text variant="footnote" weight="600">
              {i18n.t(`approvals.level.${s.level}`)}
            </Text>
            {` · ${s.approver.name}`}
          </Text>
          <Text variant="caption" style={{ color: color(s.status) }} weight="600">
            {i18n.t(`approvals.step.${s.status}`)}
          </Text>
        </View>
      ))}
    </View>
  );
}

function ApprovalCard({ item }: { item: ApprovalItem }) {
  const t = useTheme();
  const i18n = useI18n();
  const now = useNow(60_000);
  const decide = useDecide();
  const session = useSession();
  const [returning, setReturning] = useState(false);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const { summary, detail } = describe(item, i18n);
  const reviewPending = item.steps.some((s) => s.level === 'supervisor' && s.status === 'pending');
  const finalAsManager = item.actingAs === 'manager';

  const submit = (decision: 'approve' | 'return') => {
    setError(null);
    decide.mutate(
      { id: item.id, decision, ...(decision === 'return' ? { reason } : {}) },
      {
        onSuccess: () => {
          haptics.success();
          AccessibilityInfo.announceForAccessibility(i18n.t(decision === 'approve' ? 'approvals.approved' : 'approvals.returned'));
        },
        onError: (e) => {
          haptics.error();
          setError(errorMessage(e, i18n.t('common.errorBody')));
        },
      },
    );
  };

  return (
    <Card style={{ gap: t.space.md }}>
      <View style={styles.header}>
        <Avatar initials={item.requester.initials} hue={item.requester.hue} size={44} />
        <View style={{ flex: 1 }}>
          <Text variant="headline" numberOfLines={1}>
            {item.requester.name}
          </Text>
          <Text variant="footnote" color="textSecondary" numberOfLines={1}>
            {[item.teamName, i18n.relative(item.submittedAt, now)].filter(Boolean).join(' · ')}
          </Text>
        </View>
        <Pill label={i18n.t(`approvals.kind.${item.kind}`)} tone={KIND_TONE[item.kind]} />
      </View>
      <View style={{ gap: 2 }}>
        <Text variant="body" weight="600">
          {summary}
        </Text>
        <Text variant="subhead" color="textSecondary" numberOfLines={2}>
          {detail}
        </Text>
      </View>
      <View style={[styles.chain, { backgroundColor: t.colors.fill, borderRadius: t.shape.control }]}>
        <ChainStepper steps={item.steps} i18n={i18n} />
      </View>

      {item.status !== 'pending' ? (
        <Pill label={i18n.t(`approvals.status.${item.status}`)} tone={item.status === 'approved' ? 'success' : 'danger'} />
      ) : !item.canDecide ? (
        <Text variant="footnote" color="textTertiary">
          {i18n.t('approvals.waitingOnOthers')}
        </Text>
      ) : (
        <>
          {finalAsManager && reviewPending && (
            <View style={styles.note}>
              <Icon name="hierarchy" size={14} color={t.colors.primary} />
              <Text variant="caption" color="primary" style={{ flex: 1 }}>
                {i18n.t('approvals.managerOverride')}
              </Text>
            </View>
          )}
          {returning && (
            <TextInput
              value={reason}
              onChangeText={setReason}
              placeholder={i18n.t('approvals.returnPlaceholder')}
              placeholderTextColor={t.colors.textTertiary}
              autoFocus
              multiline
              maxLength={500}
              accessibilityLabel={i18n.t('approvals.returnPlaceholder')}
              style={[t.type.body, styles.input, { color: t.colors.text, backgroundColor: t.colors.fill, borderRadius: t.shape.control }]}
            />
          )}
          {error !== null && (
            <Text variant="footnote" color="danger" accessibilityRole="alert">
              {error}
            </Text>
          )}
          <View style={[styles.actions, { gap: t.space.md }]}>
            {returning ? (
              <>
                <Button title={i18n.t('common.cancel')} variant="plain" size="small" onPress={() => setReturning(false)} style={styles.flex} />
                <Button title={i18n.t('approvals.return')} variant="destructive" size="small" onPress={() => submit('return')} loading={decide.isPending} disabled={reason.trim().length === 0} style={styles.flex} />
              </>
            ) : (
              <>
                <Button title={i18n.t('approvals.return')} variant="tonal" size="small" onPress={() => setReturning(true)} style={styles.flex} />
                <Button
                  title={i18n.t(finalAsManager ? 'approvals.approveFinal' : 'approvals.endorse')}
                  icon="check"
                  size="small"
                  onPress={() => submit('approve')}
                  loading={decide.isPending}
                  style={styles.flex}
                  accessibilityHint={session.data !== undefined && finalAsManager ? i18n.t('approvals.finalHint') : undefined}
                />
              </>
            )}
          </View>
        </>
      )}
    </Card>
  );
}

const styles = StyleSheet.create({
  grid: { flexDirection: 'row', flexWrap: 'wrap' },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  chain: { padding: 10 },
  step: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  stepDot: { width: 16, height: 16, borderRadius: 8, borderWidth: 2, alignItems: 'center', justifyContent: 'center' },
  note: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  actions: { flexDirection: 'row' },
  flex: { flex: 1 },
  input: { minHeight: 72, padding: 12, textAlignVertical: 'top' },
});
