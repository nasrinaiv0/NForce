import { Stack } from 'expo-router';

import { useStackOptions } from '@/hooks/useStackOptions';
import { useI18n } from '@/i18n';

export default function MoreStack() {
  const options = useStackOptions();
  const { t } = useI18n();
  return (
    <Stack screenOptions={options}>
      <Stack.Screen name="index" options={{ title: t('tabs.more') }} />
      <Stack.Screen name="approvals" options={{ title: t('approvals.title') }} />
      <Stack.Screen name="team" options={{ title: t('module.team') }} />
      <Stack.Screen name="customize" options={{ title: t('customize.title') }} />
      <Stack.Screen name="timesheets" options={{ title: t('timesheet.title') }} />
      <Stack.Screen name="timeoff" options={{ title: t('timeoff.title') }} />
      <Stack.Screen name="module/[id]" options={{ title: '' }} />
    </Stack>
  );
}
