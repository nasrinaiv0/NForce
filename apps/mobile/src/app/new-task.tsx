import { addDays, localDateKey, type DateKey, type TaskPriority } from '@nforce/core';
import { router } from 'expo-router';
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, StyleSheet, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { z } from 'zod';

import { Button } from '@/components/Button';
import { Chip } from '@/components/Controls';
import { Text } from '@/components/Text';
import { errorMessage, useCreateTask, useSession } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';

const TaskForm = z.object({
  title: z.string().trim().min(1).max(200),
  priority: z.enum(['low', 'normal', 'high', 'urgent']),
});

type DueChoice = 'none' | 'today' | 'tomorrow' | 'nextWeek';
const PRIORITIES: readonly TaskPriority[] = ['low', 'normal', 'high', 'urgent'];

export default function NewTaskSheet() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const insets = useSafeAreaInsets();
  const session = useSession();
  const create = useCreateTask();
  const [title, setTitle] = useState('');
  const [due, setDue] = useState<DueChoice>('today');
  const [priority, setPriority] = useState<TaskPriority>('normal');
  const [error, setError] = useState<string | null>(null);

  const today = localDateKey(new Date(), session.data?.organization.timeZone ?? 'UTC');
  const dueDate: Record<DueChoice, DateKey | undefined> = {
    none: undefined,
    today,
    tomorrow: addDays(today, 1),
    nextWeek: addDays(today, 7),
  };

  const submit = () => {
    const parsed = TaskForm.safeParse({ title, priority });
    if (!parsed.success) {
      haptics.error();
      setError(tr('work.titleRequired'));
      return;
    }
    const date = dueDate[due];
    create.mutate(
      { title: parsed.data.title, priority: parsed.data.priority, ...(date !== undefined ? { due: date } : {}) },
      {
        onSuccess: () => {
          haptics.success();
          router.back();
        },
        onError: (e) => setError(errorMessage(e, tr('common.errorBody'))),
      },
    );
  };

  return (
    <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
      <View style={[styles.sheet, { padding: t.space.xl, paddingBottom: insets.bottom + t.space.xl, gap: t.space.xl, backgroundColor: t.colors.surfaceRaised }]}>
        <View style={styles.header}>
          <Button title={tr('common.cancel')} variant="plain" size="small" onPress={() => router.back()} />
          <Text variant="headline" accessibilityRole="header">
            {tr('work.new')}
          </Text>
          <Button title={tr('common.save')} variant="plain" size="small" onPress={submit} loading={create.isPending} />
        </View>

        <TextInput
          value={title}
          onChangeText={(v) => {
            setTitle(v);
            if (error !== null) setError(null);
          }}
          placeholder={tr('work.titlePlaceholder')}
          placeholderTextColor={t.colors.textTertiary}
          autoFocus
          returnKeyType="done"
          onSubmitEditing={submit}
          maxLength={200}
          accessibilityLabel={tr('work.titlePlaceholder')}
          style={[
            t.type.title2,
            styles.input,
            { color: t.colors.text, backgroundColor: t.colors.fill, borderRadius: t.shape.control, paddingHorizontal: t.space.lg },
          ]}
        />
        {error !== null && (
          <Text variant="footnote" color="danger" accessibilityRole="alert">
            {error}
          </Text>
        )}

        <Field label={tr('work.due')}>
          <Chip label={tr('common.today')} selected={due === 'today'} onPress={() => setDue('today')} />
          <Chip label={tr('common.tomorrow')} selected={due === 'tomorrow'} onPress={() => setDue('tomorrow')} />
          <Chip label={tr('work.nextWeek')} selected={due === 'nextWeek'} onPress={() => setDue('nextWeek')} />
          <Chip label={tr('work.noDue')} selected={due === 'none'} onPress={() => setDue('none')} />
        </Field>

        <Field label={tr('work.priority')}>
          {PRIORITIES.map((p) => (
            <Chip key={p} label={tr(`work.priority.${p}`)} selected={priority === p} onPress={() => setPriority(p)} />
          ))}
        </Field>
      </View>
    </KeyboardAvoidingView>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  const t = useTheme();
  return (
    <View style={{ gap: t.space.sm }}>
      <Text variant="footnote" color="textSecondary" weight="600" style={{ textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </Text>
      <View style={styles.chips}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  sheet: { flex: 1 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  input: { minHeight: 56, paddingVertical: 12 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
