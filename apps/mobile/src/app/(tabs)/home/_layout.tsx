import { Stack, router } from 'expo-router';
import { View } from 'react-native';

import { Icon } from '@/components/Icon';
import { Touchable } from '@/components/Touchable';
import { useNotifications } from '@/data/queries';
import { useTheme } from '@/design/theme';
import { useStackOptions } from '@/hooks/useStackOptions';
import { useI18n } from '@/i18n';

export default function HomeStack() {
  const options = useStackOptions();
  const { t } = useI18n();
  return (
    <Stack screenOptions={options}>
      <Stack.Screen name="index" options={{ title: t('tabs.home'), headerRight: () => <Bell /> }} />
    </Stack>
  );
}

function Bell() {
  const theme = useTheme();
  const { t } = useI18n();
  const notifications = useNotifications();
  const unread = (notifications.data ?? []).filter((n) => !n.read).length;
  return (
    <Touchable
      onPress={() => router.navigate('/more/notifications')}
      feedback="none"
      hitSlop={12}
      accessibilityLabel={unread > 0 ? `${t('notify.title')}, ${unread}` : t('notify.title')}
      style={{ paddingHorizontal: 8 }}
    >
      <View>
        <Icon name="bell" size={22} color={theme.colors.primary} />
        {unread > 0 && <View style={{ position: 'absolute', top: -1, right: -1, width: 9, height: 9, borderRadius: 5, backgroundColor: theme.colors.danger }} />}
      </View>
    </Touchable>
  );
}
