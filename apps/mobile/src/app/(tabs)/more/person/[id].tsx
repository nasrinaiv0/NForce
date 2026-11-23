import { UserId } from '@nforce/core';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Avatar, Pill } from '@/components/Display';
import { Icon } from '@/components/Icon';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useOffboardEmployee, useProfile, useSession } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

/** Person profile. Sensitive HR fields are only returned by the server to the person and HR. */
export default function PersonScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const { id } = useLocalSearchParams<{ id: string }>();
  const profile = useProfile(UserId(String(id)));
  const session = useSession();
  const offboard = useOffboardEmployee();
  const [confirming, setConfirming] = useState(false);
  const p = profile.data;
  if (profile.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void profile.refetch()} message={errorMessage(profile.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (p === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={3} height={90} />
      </Screen>
    );
  }
  const canSeeTimesheet = session.data?.user.id === p.person.id || (session.data?.modules.includes('team') ?? false);
  const weekday = (n: number) => i18n.date(`2024-01-0${n}` as never, { weekday: 'long' });
  return (
    <Screen maxWidth={900}>
      <Stack.Screen options={{ title: p.person.name }} />
      <Card style={styles.header}>
        <Avatar initials={p.person.initials} hue={p.person.hue} size={64} />
        <View style={{ flex: 1, gap: 4 }}>
          <Text variant="title2">{p.person.name}</Text>
          <Text variant="subhead" color="textSecondary">
            {p.person.title}
          </Text>
          <View style={styles.row}>
            <Pill label={i18n.t(`role.${p.role}`)} tone="primary" icon="shield" />
            <Text variant="footnote" color="textTertiary">
              {[p.department, p.teamName].filter(Boolean).join(' · ')}
            </Text>
          </View>
        </View>
      </Card>
      <ListSection title={i18n.t('people.work')}>
        <ListRow title={i18n.t('people.location')} value={p.location} icon="location" iconTint="#34C759" />
        <ListRow title={i18n.t('people.shift')} value={p.shift} icon="clock" iconTint="#007AFF" />
        <ListRow title={i18n.t('people.restDays')} value={p.restDays.map(weekday).join(', ')} icon="restDay" iconTint="#5856D6" last />
      </ListSection>
      <ListSection title={i18n.t('people.reportingLine')}>
        {p.chain.length === 0 ? (
          <ListRow title={i18n.t('people.topOfOrg')} icon="hierarchy" iconTint="#8E8E93" last />
        ) : (
          p.chain.map((m, i) => (
            <ListRow
              key={m.id}
              title={m.name}
              subtitle={m.title}
              leading={<Avatar initials={m.initials} hue={m.hue} size={32} />}
              onPress={() => router.push({ pathname: '/more/person/[id]', params: { id: m.id } })}
              last={i === p.chain.length - 1}
            />
          ))
        )}
      </ListSection>
      {p.directReports.length > 0 && (
        <ListSection title={i18n.t('people.directReports', { count: p.directReports.length })}>
          {p.directReports.map((m, i) => (
            <ListRow key={m.id} title={m.name} subtitle={m.title} leading={<Avatar initials={m.initials} hue={m.hue} size={32} />} onPress={() => router.push({ pathname: '/more/person/[id]', params: { id: m.id } })} last={i === p.directReports.length - 1} />
          ))}
        </ListSection>
      )}
      {p.sensitive !== undefined ? (
        <ListSection title={i18n.t('people.confidential')} footer={i18n.t('people.confidentialFooter')}>
          <ListRow title={i18n.t('people.employeeId')} value={p.sensitive.employeeId} />
          <ListRow title={i18n.t('people.hireDate')} value={i18n.date(p.sensitive.hireDate, { year: 'numeric', month: 'long', day: 'numeric' })} />
          <ListRow title={i18n.t('people.payGrade')} value={p.sensitive.payGrade} />
          <ListRow title={i18n.t('people.emergency')} value={p.sensitive.emergencyContact} last />
        </ListSection>
      ) : (
        <Card style={[styles.row, { backgroundColor: t.colors.fill }]}>
          <Icon name="shield" size={18} color={t.colors.textSecondary} />
          <Text variant="footnote" color="textSecondary" style={{ flex: 1 }}>
            {i18n.t('people.restricted')}
          </Text>
        </Card>
      )}
      {p.person.id !== session.data?.user.id && !p.access.canEdit && !p.access.canOffboard && (session.data?.capabilities.managePeople === true || session.data?.capabilities.offboard === true) && (
        <Card style={[styles.row, { backgroundColor: t.colors.fill }]}>
          <Icon name="shield" size={18} color={t.colors.textSecondary} />
          <Text variant="footnote" color="textSecondary" style={{ flex: 1 }}>
            {i18n.t(p.role === 'owner' ? 'people.protected' : 'people.noAccessHere')}
          </Text>
        </Card>
      )}
      {(p.access.canEdit || p.access.canOffboard) && (
        <Card style={{ gap: t.space.md }}>
          <Text variant="headline">{i18n.t('people.manage')}</Text>
          <View style={styles.row}>
            {p.access.canEdit && (
              <Button title={i18n.t('people.edit')} icon="settings" variant="tonal" size="small" onPress={() => router.push({ pathname: '/employee-form', params: { id: p.person.id } })} />
            )}
            {p.access.canOffboard && !confirming && (
              <Button title={i18n.t('people.offboard')} icon="logout" variant="destructive" size="small" onPress={() => setConfirming(true)} />
            )}
          </View>
          {confirming && (
            <View style={[styles.confirm, { backgroundColor: t.colors.dangerContainer, borderRadius: t.shape.control }]}>
              <Text variant="footnote" style={{ color: t.colors.danger }}>
                {i18n.t('people.offboardConfirm', { name: p.person.name, count: p.directReports.length })}
              </Text>
              <View style={styles.row}>
                <Button title={i18n.t('common.cancel')} variant="plain" size="small" onPress={() => setConfirming(false)} />
                <Button
                  title={i18n.t('people.offboard')}
                  variant="destructive"
                  size="small"
                  loading={offboard.isPending}
                  onPress={() =>
                    offboard.mutate(p.person.id, {
                      onSuccess: () => {
                        haptics.success();
                        router.back();
                      },
                      onError: () => haptics.error(),
                    })
                  }
                />
              </View>
            </View>
          )}
          {offboard.isError && (
            <Text variant="footnote" color="danger" accessibilityRole="alert">
              {errorMessage(offboard.error, i18n.t('common.errorBody'))}
            </Text>
          )}
        </Card>
      )}
      {canSeeTimesheet && <Button title={i18n.t('timesheet.title')} icon="timesheets" variant="tonal" onPress={() => router.push({ pathname: '/more/timesheets', params: { user: p.person.id } })} />}
    </Screen>
  );
}

const styles = StyleSheet.create({
  header: { flexDirection: 'row', alignItems: 'center', gap: 16 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
  confirm: { padding: 12, gap: 8 },
});
