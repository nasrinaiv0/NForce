import { formatDuration, timesheetTotalMinutes, type TimesheetStatus } from '@nforce/core';
import { StyleSheet, View } from 'react-native';

import { Button } from '@/components/Button';
import { Pill, type Tone } from '@/components/Display';
import { ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card, ListRow, ListSection } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useSession, useTimesheet, useTimesheetAction } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const STATUS_TONE: Readonly<Record<TimesheetStatus, Tone>> = {
  draft: 'neutral',
  submitted: 'info',
  returned: 'warning',
  approved: 'success',
  locked: 'primary',
};

export default function TimesheetScreen() {
  const t = useTheme();
  const i18n = useI18n();
  const session = useSession();
  const sheet = useTimesheet();
  const act = useTimesheetAction();
  const tz = session.data?.organization.timeZone ?? 'UTC';

  if (sheet.isError) {
    return (
      <Screen>
        <ErrorState onRetry={() => void sheet.refetch()} message={errorMessage(sheet.error, i18n.t('common.errorBody'))} />
      </Screen>
    );
  }
  if (sheet.data === undefined) {
    return (
      <Screen>
        <LoadingBlock rows={3} height={90} />
      </Screen>
    );
  }
  const s = sheet.data;
  const total = timesheetTotalMinutes(s);
  const range = `${i18n.date(s.periodStart, { month: 'short', day: 'numeric' })} – ${i18n.date(s.periodEnd, { month: 'short', day: 'numeric' })}`;

  return (
    <Screen onRefresh={() => sheet.refetch()}>
      <Card style={{ gap: t.space.md }}>
        <View style={styles.row}>
          <Text variant="subhead" color="textSecondary">
            {range}
          </Text>
          <Pill label={i18n.t(`timesheet.status.${s.status}`)} tone={STATUS_TONE[s.status]} dot />
        </View>
        <Text variant="largeTitle" tabular accessibilityLabel={`${i18n.t('timesheet.total')}: ${formatDuration(total)}`}>
          {formatDuration(total)}
        </Text>
        {s.actions.map((action) => (
          <Button
            key={action}
            title={i18n.t(`timesheet.action.${action}`)}
            onPress={() => act.mutate({ action }, { onSuccess: () => haptics.success(), onError: () => haptics.error() })}
            loading={act.isPending}
          />
        ))}
        {act.isError && (
          <Text variant="footnote" color="danger" accessibilityRole="alert">
            {errorMessage(act.error, i18n.t('common.errorBody'))}
          </Text>
        )}
      </Card>

      <ListSection footer={i18n.t('timesheet.footer')}>
        {s.entries.length === 0 ? (
          <Text variant="subhead" color="textSecondary" style={{ padding: t.space.lg }}>
            {i18n.t('timesheet.noEntries')}
          </Text>
        ) : (
          s.entries.map((e, idx) => (
            <ListRow
              key={e.date}
              title={i18n.date(e.date, { weekday: 'long', month: 'short', day: 'numeric' })}
              subtitle={`${i18n.t('clock.breaks')}: ${formatDuration(e.breakMinutes)}`}
              value={formatDuration(e.workedMinutes)}
              last={idx === s.entries.length - 1}
            />
          ))
        )}
      </ListSection>

      {s.history.length > 0 && (
        <ListSection title={i18n.t('timesheet.history')}>
          {s.history.map((h, idx) => (
            <ListRow
              key={`${h.at}-${idx}`}
              title={i18n.t(`timesheet.status.${h.to}`)}
              subtitle={h.reason}
              value={i18n.time(h.at, tz)}
              last={idx === s.history.length - 1}
            />
          ))}
        </ListSection>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
});
