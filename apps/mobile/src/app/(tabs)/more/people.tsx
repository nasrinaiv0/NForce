import { router } from 'expo-router';
import { useMemo } from 'react';
import { StyleSheet, View } from 'react-native';

import { Avatar, Pill } from '@/components/Display';
import { ListControls, useListView } from '@/components/ListView';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Button } from '@/components/Button';
import { directoryFields } from '@/data/listFields';
import { errorMessage, useDirectory, useSession } from '@/data/queries';
import type { DirectoryEntry } from '@/data/types';
import { useTheme } from '@/design/theme';
import { useResponsive } from '@/hooks/useResponsive';
import { useI18n } from '@/i18n';

/** Organization directory (non-sensitive fields only). */
export default function PeopleScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { columns } = useResponsive();
  const directory = useDirectory();
  const session = useSession();
  const canAdd = session.data?.capabilities.managePeople ?? false;
  const people = useMemo(() => directory.data ?? [], [directory.data]);
  const departments = useMemo(() => [...new Set(people.map((p) => p.department))].sort(), [people]);
  const fields = useMemo(() => directoryFields(i18n), [i18n]);
  const list = useListView({
    id: 'people',
    fields,
    defaultSort: { key: 'name', direction: 'asc' },
    searchText: (p) => [p.person.name, p.person.title, p.teamName, p.department, i18n.t(`role.${p.role}`)],
    quickFilters: [{ value: 'all', label: i18n.t('list.all') }, ...departments.map((d) => ({ value: `dept:${d}`, label: d, test: (p: DirectoryEntry) => p.department === d }))],
  });
  const rows = list.apply(people);
  return (
    <Screen onRefresh={() => directory.refetch()} maxWidth={1320}>
      {canAdd && <Button title={i18n.t('people.form.add')} icon="add" onPress={() => router.push('/employee-form')} style={{ alignSelf: 'flex-start' }} />}
      <ListControls
        state={list}
        searchPlaceholder={i18n.t('people.search')}
        resultCount={rows.length}
        quickCounts={{ all: people.length, ...Object.fromEntries(departments.map((d) => [`dept:${d}`, people.filter((p) => p.department === d).length])) }}
      />
      {directory.isError ? (
        <ErrorState onRetry={() => void directory.refetch()} message={errorMessage(directory.error, i18n.t('common.errorBody'))} />
      ) : directory.data === undefined ? (
        <LoadingBlock rows={5} height={72} />
      ) : rows.length === 0 ? (
        <EmptyState icon="people" title={i18n.t('list.noMatches')} />
      ) : (
        <View style={[styles.grid, { gap: t.space.md }]}>
          {rows.map((p) => (
            <View key={p.person.id} style={{ flexBasis: columns === 1 ? '100%' : columns === 2 ? '48%' : '31%', flexGrow: 1 }}>
              <Card onPress={() => router.push({ pathname: '/more/person/[id]', params: { id: p.person.id } })} accessibilityLabel={`${p.person.name}, ${p.person.title}`} style={styles.card}>
                <Avatar initials={p.person.initials} hue={p.person.hue} size={44} />
                <View style={{ flex: 1, gap: 2 }}>
                  <Text variant="headline" numberOfLines={1}>
                    {p.person.name}
                  </Text>
                  <Text variant="footnote" color="textSecondary" numberOfLines={1}>
                    {p.person.title}
                  </Text>
                  <Text variant="caption" color="textTertiary" numberOfLines={1}>
                    {[p.department, p.teamName].filter(Boolean).join(' · ')}
                  </Text>
                </View>
                <Pill label={i18n.t(`role.${p.role}`)} tone="neutral" />
              </Card>
            </View>
          ))}
        </View>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  grid: { flexDirection: 'row', flexWrap: 'wrap' },
  card: { flexDirection: 'row', alignItems: 'center', gap: 12 },
});
