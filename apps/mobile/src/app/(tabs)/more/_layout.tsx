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
      <Stack.Screen name="attendance" options={{ title: t('module.attendance') }} />
      <Stack.Screen name="reports" options={{ title: t('module.reports') }} />
      <Stack.Screen name="people" options={{ title: t('module.people') }} />
      <Stack.Screen name="person/[id]" options={{ title: '' }} />
      <Stack.Screen name="payroll" options={{ title: t('module.payroll') }} />
      <Stack.Screen name="admin" options={{ title: t('module.admin') }} />
      <Stack.Screen name="crm" options={{ title: t('module.crm') }} />
      <Stack.Screen name="notifications" options={{ title: t('notify.title') }} />
    </Stack>
  );
}
