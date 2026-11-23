import { facetCounts, groupTasks, localDateKey, type Task, type TaskBucket } from '@nforce/core';
import { Stack, router } from 'expo-router';
import { useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Checkbox, Fab, SegmentedControl } from '@/components/Controls';
import { Pill, type Tone } from '@/components/Display';
import { ListControls, useListView } from '@/components/ListView';
import { Icon } from '@/components/Icon';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { taskFields } from '@/data/listFields';
import { useSession, useSetTaskDone, useTasks } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useI18n, type I18n } from '@/i18n';

type Filter = 'open' | 'all';
const PRIORITY_TONE: Readonly<Record<Task['priority'], Tone | null>> = { urgent: 'danger', high: 'warning', normal: null, low: null };

export default function WorkScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { t: tr } = i18n;
  const session = useSession();
  const tasks = useTasks();
  const [filter, setFilter] = useState<Filter>('open');
  const today = localDateKey(new Date(), session.data?.organization.timeZone ?? 'UTC');
  const counts = facetCounts(tasks.data ?? [], (x) => x.priority);
  const fields = useMemo(() => taskFields(i18n), [i18n]);
  const list = useListView({
    id: 'work',
    fields,
    defaultSort: { key: 'priority', direction: 'asc' },
    searchText: (x) => [x.title, x.link?.label],
    quickFilters: [
      { value: 'any', label: tr('work.anyPriority') },
      ...(['urgent', 'high', 'normal', 'low'] as const).map((p) => ({ value: p, label: tr(`work.priority.${p}`), test: (x: Task) => x.priority === p })),
    ],
  });
  // Search, filters and sort apply within each due-date group.
  const all = groupTasks(tasks.data ?? [], today)
    .map((g) => ({ bucket: g.bucket, tasks: list.apply(g.tasks) }))
    .filter((g) => g.tasks.length > 0);
  const groups = filter === 'open' ? all.filter((g) => g.bucket !== 'done') : all;
  const shown = groups.reduce((n, g) => n + g.tasks.length, 0);
  const openNew = () => router.push('/new-task');

  return (
    <>
      <Stack.Screen
        options={{
          headerRight:
            t.flavor === 'ios'
              ? () => (
                  <Touchable onPress={openNew} feedback="none" hitSlop={12} accessibilityLabel={tr('work.new')} haptic="light">
                    <Icon name="add" size={22} color={t.colors.primary} weight="semibold" />
                  </Touchable>
                )
              : undefined,
        }}
      />
      <Screen onRefresh={() => tasks.refetch()} footer={<Fab icon="add" label={tr('work.new')} onPress={openNew} />}>
        <SegmentedControl<Filter>
          segments={[
            { value: 'open', label: tr('work.filter.open') },
            { value: 'all', label: tr('work.filter.all') },
          ]}
          value={filter}
          onChange={setFilter}
        />
        <ListControls state={list} searchPlaceholder={tr('work.search')} resultCount={shown} quickCounts={{ any: tasks.data?.length ?? 0, ...Object.fromEntries(counts) }} />
        {tasks.isError ? (
          <ErrorState onRetry={() => void tasks.refetch()} />
        ) : tasks.data === undefined ? (
          <LoadingBlock rows={4} height={56} />
        ) : groups.length === 0 ? (
          list.search.length > 0 || list.quick !== 'any' || list.activeCount > 0 ? (
            <EmptyState icon="search" title={tr('list.noMatches')} />
          ) : (
            <EmptyState icon="sparkles" title={tr('work.emptyTitle')} body={tr('work.emptyBody')} />
          )
        ) : (
          groups.map((g) => (
            <ListSection key={g.bucket} title={`${tr(`work.bucket.${g.bucket}`)} · ${g.tasks.length}`}>
              {g.tasks.map((task, idx) => (
                <TaskRow key={task.id} task={task} bucket={g.bucket} last={idx === g.tasks.length - 1} i18n={i18n} />
              ))}
            </ListSection>
          ))
        )}
      </Screen>
    </>
  );
}

function TaskRow({ task, bucket, last, i18n }: { task: Task; bucket: TaskBucket; last: boolean; i18n: I18n }) {
  const t = useTheme();
  const setDone = useSetTaskDone();
  const done = task.status === 'done';
  const tone = PRIORITY_TONE[task.priority];
  const due = task.due === undefined ? null : i18n.date(task.due, { weekday: 'short', month: 'short', day: 'numeric' });
  return (
    <View style={[styles.row, { paddingLeft: t.space.sm }]}>
      <Checkbox
        checked={done}
        onToggle={() => setDone.mutate({ id: task.id, done: !done })}
        label={i18n.t(done ? 'work.markOpen' : 'work.markDone', { title: task.title })}
      />
      <View
        style={[
          styles.body,
          { paddingRight: t.space.lg },
          !last && t.flavor === 'ios' && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator },
        ]}
      >
        <View style={{ flex: 1, gap: 2, paddingVertical: t.space.md }}>
          <Text
            variant="body"
            color={done ? 'textTertiary' : 'text'}
            style={done ? { textDecorationLine: 'line-through' } : undefined}
            numberOfLines={2}
          >
            {task.title}
          </Text>
          {(due !== null || task.link !== undefined) && (
            <View style={styles.meta}>
              {due !== null && (
                <Text variant="footnote" color={bucket === 'overdue' ? 'danger' : 'textSecondary'}>
                  {due}
                </Text>
              )}
              {task.link !== undefined && (
                <View style={styles.meta}>
                  <Icon name="link" size={12} color={t.colors.primary} />
                  <Text variant="footnote" color="primary">
                    {task.link.label}
                  </Text>
                </View>
              )}
            </View>
          )}
        </View>
        {tone !== null && !done && <Pill label={i18n.t(`work.priority.${task.priority}`)} tone={tone} />}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  body: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, alignSelf: 'stretch', minHeight: 52 },
  meta: { flexDirection: 'row', alignItems: 'center', gap: 8 },
});
