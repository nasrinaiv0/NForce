import { formatDuration } from '@nforce/core';
import { useState } from 'react';
import { AccessibilityInfo, StyleSheet, TextInput, View } from 'react-native';

import { Button } from '@/components/Button';
import { Avatar, Pill, type Tone } from '@/components/Display';
import { EmptyState, ErrorState, LoadingBlock, Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { errorMessage, useApprovals, useDecide, useSession } from '@/data/queries';
import type { ApprovalItem, ApprovalKind } from '@/data/types';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useNow } from '@/hooks/useNow';
import { useI18n, type I18n } from '@/i18n';

const KIND_TONE: Readonly<Record<ApprovalKind, Tone>> = { timesheet: 'primary', leave: 'success', correction: 'warning' };

export default function ApprovalsScreen() {
  const { t } = useI18n();
  const approvals = useApprovals();
  return (
    <Screen onRefresh={() => approvals.refetch()}>
      {approvals.isError ? (
        <ErrorState onRetry={() => void approvals.refetch()} message={errorMessage(approvals.error, t('common.errorBody'))} />
      ) : approvals.data === undefined ? (
        <LoadingBlock rows={3} height={150} />
      ) : approvals.data.length === 0 ? (
        <EmptyState icon="checkCircle" title={t('approvals.emptyTitle')} body={t('approvals.emptyBody')} />
      ) : (
        approvals.data.map((item) => <ApprovalCard key={item.id} item={item} />)
      )}
    </Screen>
  );
}

function ApprovalCard({ item }: { item: ApprovalItem }) {
  const t = useTheme();
  const i18n = useI18n();
  const now = useNow(60_000);
  const decide = useDecide();
  const [returning, setReturning] = useState(false);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const session = useSession();
  const { summary, detail } = describe(item, i18n, session.data?.organization.timeZone ?? 'UTC');

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
          <Text variant="headline">{item.requester.name}</Text>
          <Text variant="footnote" color="textSecondary">
            {i18n.relative(item.submittedAt, now)}
          </Text>
        </View>
        <Pill label={i18n.t(`approvals.kind.${item.kind}`)} tone={KIND_TONE[item.kind]} />
      </View>
      <View style={{ gap: 2 }}>
        <Text variant="body" weight="600">
          {summary}
        </Text>
        <Text variant="subhead" color="textSecondary">
          {detail}
        </Text>
      </View>

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
            <Button
              title={i18n.t('approvals.return')}
              variant="destructive"
              size="small"
              onPress={() => submit('return')}
              loading={decide.isPending}
              disabled={reason.trim().length === 0}
              style={styles.flex}
            />
          </>
        ) : (
          <>
            <Button title={i18n.t('approvals.return')} variant="tonal" size="small" onPress={() => setReturning(true)} style={styles.flex} />
            <Button
              title={i18n.t('approvals.approve')}
              icon="check"
              size="small"
              onPress={() => submit('approve')}
              loading={decide.isPending}
              style={styles.flex}
            />
          </>
        )}
      </View>
    </Card>
  );
}

/** Localized headline + detail for each approval kind. */
function describe(item: ApprovalItem, i18n: I18n, timeZone: string): { summary: string; detail: string } {
  const short = { month: 'short', day: 'numeric' } as const;
  switch (item.kind) {
    case 'timesheet':
      return {
        summary: i18n.t('approvals.timesheetSummary', { hours: formatDuration(item.minutes) }),
        detail: i18n.t('approvals.weekOf', { date: i18n.date(item.periodStart, short) }),
      };
    case 'leave':
      return {
        summary: i18n.t('approvals.leaveSummary', {
          type: item.leaveType ?? i18n.t('timeoff.kind.day_off'),
          days: i18n.plural('timeoff.days', item.days),
        }),
        detail: item.start === item.end ? i18n.date(item.start) : `${i18n.date(item.start)} – ${i18n.date(item.end)}`,
      };
    case 'correction':
      return {
        summary: i18n.t('approvals.missedClockOut'),
        detail: i18n.t('approvals.requestedTime', { date: i18n.date(item.date), time: i18n.time(item.requestedAt, timeZone) }),
      };
  }
}

const styles = StyleSheet.create({
  header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  actions: { flexDirection: 'row' },
  flex: { flex: 1 },
  input: { minHeight: 72, padding: 12, textAlignVertical: 'top' },
});
