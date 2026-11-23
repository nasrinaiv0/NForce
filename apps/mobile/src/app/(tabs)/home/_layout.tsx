import { Stack } from 'expo-router';

import { useStackOptions } from '@/hooks/useStackOptions';
import { useI18n } from '@/i18n';

export default function HomeStack() {
  const options = useStackOptions();
  const { t } = useI18n();
  return (
    <Stack screenOptions={options}>
      <Stack.Screen name="index" options={{ title: t('tabs.home') }} />
    </Stack>
  );
}
