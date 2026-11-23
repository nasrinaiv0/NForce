import { isDateKey, localDateKey, type DateKey } from '@nforce/core';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { Button } from '@/components/Button';
import { Chip, SegmentedControl } from '@/components/Controls';
import { Icon } from '@/components/Icon';
import { RangeCalendar, type DateRange } from '@/components/RangeCalendar';
import { Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { LEAVE_TYPES } from '@/data/mockApi';
import { api, errorMessage, keys, useRequestTimeOff, useSession } from '@/data/queries';
import type { TimeOffInput } from '@/data/types';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

type Kind = TimeOffInput['kind'];

export default function RequestTimeOff() {
  const t = useTheme();
  const i18n = useI18n();
  const params = useLocalSearchParams<{ kind?: string; start?: string }>();
  const session = useSession();
  const today = localDateKey(new Date(), session.data?.organization.timeZone ?? 'UTC');
  const initialStart = params.start !== undefined && isDateKey(params.start) && params.start >= today ? (params.start as DateKey) : undefined;

  const [kind, setKind] = useState<Kind>(params.kind === 'day_off' ? 'day_off' : 'leave');
  const [leaveTypeId, setLeaveTypeId] = useState(LEAVE_TYPES[0]?.id ?? 'vacation');
  const [range, setRange] = useState<DateRange>(initialStart !== undefined ? { start: initialStart } : {});
  const [halfDay, setHalfDay] = useState(false);
  const [note, setNote] = useState('');
  const submit = useRequestTimeOff();

  const end = range.end ?? range.start;
  const single = range.start !== undefined && end === range.start;
  const policy = LEAVE_TYPES.find((l) => l.id === leaveTypeId);
  const useHalfDay = kind === 'leave' && halfDay && single && policy?.allowHalfDays === true;

  const input: TimeOffInput | null =
    range.start === undefined || end === undefined
      ? null
      : {
          kind,
          start: range.start,
          end,
          ...(kind === 'leave' ? { leaveTypeId } : {}),
          ...(useHalfDay ? { halfDay: 'am' as const } : {}),
          ...(note.trim().length > 0 ? { note: note.trim() } : {}),
        };

  // Live, server-validated preview of balance impact and policy errors.
  const preview = useQuery({
    queryKey: [...keys.all, 'timeoff-preview', input],
    queryFn: () => api.previewTimeOff(input as TimeOffInput),
    enabled: input !== null,
    retry: false,
    staleTime: 0,
    placeholderData: keepPreviousData,
  });

  const send = () => {
    if (input === null) return;
    submit.mutate(input, {
      onSuccess: () => {
        haptics.success();
        router.back();
      },
      onError: () => haptics.error(),
    });
  };

  const hint = range.start === undefined ? i18n.t('timeoff.pickStart') : range.end === undefined ? i18n.t('timeoff.pickEnd') : null;
  const previewError = preview.isError ? errorMessage(preview.error, i18n.t('common.errorBody')) : null;
  const canSend = input !== null && preview.isSuccess && !preview.isPlaceholderData && !submit.isPending;

  return (
    <Screen>
      <SegmentedControl<Kind>
        segments={[
          { value: 'leave', label: i18n.t('timeoff.kind.leave') },
          { value: 'day_off', label: i18n.t('timeoff.kind.day_off') },
        ]}
        value={kind}
        onChange={setKind}
      />

      {kind === 'leave' && (
        <View style={{ gap: t.space.sm }}>
          <Label text={i18n.t('timeoff.type')} />
          <View style={styles.chips}>
            {LEAVE_TYPES.map((l) => (
              <Chip key={l.id} label={l.name} selected={leaveTypeId === l.id} onPress={() => setLeaveTypeId(l.id)} />
            ))}
          </View>
        </View>
      )}

      <Card style={{ gap: t.space.md }}>
        <RangeCalendar value={range} onChange={setRange} minDate={today} />
        {hint !== null && (
          <Text variant="footnote" color="textSecondary" align="center">
            {hint}
          </Text>
        )}
        {kind === 'leave' && single && policy?.allowHalfDays === true && (
          <View style={styles.chips}>
            <Chip label={i18n.t('timeoff.halfDay')} selected={halfDay} onPress={() => setHalfDay((v) => !v)} />
          </View>
        )}
      </Card>

      <View style={{ gap: t.space.sm }}>
        <Label text={i18n.t('timeoff.note')} />
        <TextInput
          value={note}
          onChangeText={setNote}
          multiline
          maxLength={500}
          accessibilityLabel={i18n.t('timeoff.note')}
          placeholderTextColor={t.colors.textTertiary}
          style={[t.type.body, styles.note, { color: t.colors.text, backgroundColor: t.colors.surface, borderRadius: t.shape.control }]}
        />
      </View>

      {input !== null && (
        <Card
          style={[
            styles.preview,
            { backgroundColor: previewError !== null ? t.colors.dangerContainer : kind === 'day_off' ? t.colors.infoContainer : t.colors.successContainer },
          ]}
        >
          <Icon
            name={previewError !== null ? 'warning' : 'info'}
            size={20}
            color={previewError !== null ? t.colors.danger : kind === 'day_off' ? t.colors.info : t.colors.success}
          />
          <Text variant="subhead" style={{ flex: 1, color: previewError !== null ? t.colors.danger : t.colors.text }} accessibilityLiveRegion="polite">
            {previewError ??
              (preview.data === undefined
                ? ' '
                : kind === 'day_off'
                  ? `${i18n.plural('timeoff.days', preview.data.days)} · ${i18n.t('timeoff.dayOffImpact')}`
                  : i18n.t('timeoff.impact', {
                      days: i18n.plural('timeoff.days', preview.data.days),
                      after: i18n.number(preview.data.balanceAfter ?? 0),
                    }))}
          </Text>
        </Card>
      )}

      {submit.isError && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {errorMessage(submit.error, i18n.t('common.errorBody'))}
        </Text>
      )}
      <Button title={i18n.t('timeoff.send')} icon="calendarCheck" size="large" onPress={send} disabled={!canSend} loading={submit.isPending} />
    </Screen>
  );
}

function Label({ text }: { text: string }) {
  return (
    <Text variant="footnote" color="textSecondary" weight="600" style={{ textTransform: 'uppercase', letterSpacing: 0.5 }}>
      {text}
    </Text>
  );
}

const styles = StyleSheet.create({
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  note: { minHeight: 80, padding: 14, textAlignVertical: 'top' },
  preview: { flexDirection: 'row', gap: 12, alignItems: 'flex-start' },
});
