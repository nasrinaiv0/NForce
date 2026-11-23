import { formatDuration, isDateKey, localDateKey, type DateKey } from '@nforce/core';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { ApproverChain } from '@/components/ApproverChain';
import { Button } from '@/components/Button';
import { Chip } from '@/components/Controls';
import { Icon } from '@/components/Icon';
import { Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useApproverPreview, useRequestOvertime, useSession } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const STEP = 15;

/** File overtime for a worked day. Routed supervisor → manager like every request. */
export default function RequestOvertime() {
  const t = useTheme();
  const i18n = useI18n();
  const params = useLocalSearchParams<{ date?: string; minutes?: string }>();
  const session = useSession();
  const chain = useApproverPreview();
  const submit = useRequestOvertime();
  const today = localDateKey(new Date(), session.data?.organization.timeZone ?? 'UTC');
  const date: DateKey = typeof params.date === 'string' && isDateKey(params.date) ? params.date : today;
  const initial = Math.max(STEP, Math.min(720, Math.round(Number(params.minutes ?? 60) / STEP) * STEP || 60));
  const [minutes, setMinutes] = useState(initial);
  const [reason, setReason] = useState('');
  const presets = ['otReason.backlog', 'otReason.coverage', 'otReason.escalation', 'otReason.closing'] as const;

  const send = () =>
    submit.mutate(
      { date, minutes, reason },
      {
        onSuccess: () => {
          haptics.success();
          router.back();
        },
        onError: () => haptics.error(),
      },
    );

  return (
    <Screen maxWidth={640}>
      <Card style={{ gap: t.space.lg }}>
        <View style={styles.row}>
          <Icon name="overtime" size={22} color={t.colors.primary} />
          <Text variant="headline" style={{ flex: 1 }}>
            {i18n.date(date, { weekday: 'long', month: 'long', day: 'numeric' })}
          </Text>
        </View>
        <View style={styles.stepper} accessibilityRole="adjustable" accessibilityLabel={i18n.t('overtime.duration')} accessibilityValue={{ text: formatDuration(minutes) }}>
          <StepButton label="−" onPress={() => setMinutes((m) => Math.max(STEP, m - STEP))} a11y={i18n.t('overtime.less')} />
          <Text variant="largeTitle" tabular style={{ minWidth: 150, textAlign: 'center' }}>
            {formatDuration(minutes)}
          </Text>
          <StepButton label="+" onPress={() => setMinutes((m) => Math.min(720, m + STEP))} a11y={i18n.t('overtime.more')} />
        </View>
        <Text variant="footnote" color="textSecondary" align="center">
          {i18n.t('overtime.hint')}
        </Text>
      </Card>

      <View style={{ gap: t.space.sm }}>
        <Text variant="footnote" color="textSecondary" weight="600" style={styles.label}>
          {i18n.t('overtime.reason')}
        </Text>
        <View style={styles.chips}>
          {presets.map((p) => (
            <Chip key={p} label={i18n.t(p)} selected={reason === i18n.t(p)} onPress={() => setReason(i18n.t(p))} />
          ))}
        </View>
        <TextInput
          value={reason}
          onChangeText={setReason}
          multiline
          maxLength={300}
          placeholder={i18n.t('overtime.reasonPlaceholder')}
          placeholderTextColor={t.colors.textTertiary}
          accessibilityLabel={i18n.t('overtime.reason')}
          style={[t.type.body, styles.input, { color: t.colors.text, backgroundColor: t.colors.surface, borderRadius: t.shape.control }]}
        />
      </View>

      {chain.data !== undefined && (
        <Card style={{ gap: t.space.sm }}>
          <Text variant="footnote" color="textSecondary" weight="600">
            {i18n.t('approvals.routeTo')}
          </Text>
          <ApproverChain steps={chain.data} i18n={i18n} />
        </Card>
      )}
      {chain.isError && (
        <Card style={{ backgroundColor: t.colors.fill }}>
          <Text variant="footnote" color="textSecondary" accessibilityRole="alert">
            {errorMessage(chain.error, i18n.t('common.errorBody'))}
          </Text>
        </Card>
      )}
      {submit.isError && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {errorMessage(submit.error, i18n.t('common.errorBody'))}
        </Text>
      )}
      <Button title={i18n.t('overtime.send')} icon="overtime" size="large" onPress={send} disabled={reason.trim().length === 0} loading={submit.isPending} />
    </Screen>
  );
}

function StepButton({ label, onPress, a11y }: { label: string; onPress: () => void; a11y: string }) {
  const t = useTheme();
  return (
    <Touchable onPress={onPress} haptic="selection" accessibilityLabel={a11y} style={[styles.stepBtn, { backgroundColor: t.colors.tonal }]}>
      <Text variant="title" style={{ color: t.colors.onTonal }}>
        {label}
      </Text>
    </Touchable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  stepper: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 16 },
  stepBtn: { width: 52, height: 52, borderRadius: 26, alignItems: 'center', justifyContent: 'center' },
  label: { textTransform: 'uppercase', letterSpacing: 0.5 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  input: { minHeight: 80, padding: 14, textAlignVertical: 'top' },
});
