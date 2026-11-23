import { QueryClientProvider } from '@tanstack/react-query';
import { DarkTheme, DefaultTheme, Stack, ThemeProvider as NavigationThemeProvider, type ErrorBoundaryProps } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import * as SystemUI from 'expo-system-ui';
import { useEffect, useMemo } from 'react';
import { View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { ErrorState } from '@/components/Screen';
import { queryClient } from '@/data/queries';
import { ThemeProvider, useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { hydratePreferences, usePreferencesHydrated } from '@/state/preferences';

void SplashScreen.preventAutoHideAsync().catch(() => undefined);

export default function RootLayout() {
  useEffect(() => {
    void hydratePreferences();
  }, []);
  return (
    <SafeAreaProvider>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider>
          <AppShell />
        </ThemeProvider>
      </QueryClientProvider>
    </SafeAreaProvider>
  );
}

function AppShell() {
  const t = useTheme();
  const { t: tr } = useI18n();
  const hydrated = usePreferencesHydrated();

  useEffect(() => {
    void SystemUI.setBackgroundColorAsync(t.colors.background).catch(() => undefined);
  }, [t.colors.background]);

  useEffect(() => {
    if (hydrated) SplashScreen.hide();
  }, [hydrated]);

  const navTheme = useMemo(() => {
    const base = t.scheme === 'dark' ? DarkTheme : DefaultTheme;
    return {
      ...base,
      colors: {
        ...base.colors,
        primary: t.colors.primary,
        background: t.colors.background,
        card: t.colors.background,
        text: t.colors.text,
        border: t.colors.separator,
      },
    };
  }, [t]);

  if (!hydrated) return <View style={{ flex: 1, backgroundColor: t.colors.background }} />;

  return (
    <NavigationThemeProvider value={navTheme}>
      <StatusBar style={t.scheme === 'dark' ? 'light' : 'dark'} />
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: t.colors.background } }}>
        <Stack.Screen name="(tabs)" />
        <Stack.Screen
          name="new-task"
          options={{
            presentation: 'formSheet',
            sheetAllowedDetents: [0.62, 1],
            sheetGrabberVisible: true,
            sheetCornerRadius: t.shape.sheet,
            contentStyle: { backgroundColor: t.colors.surfaceRaised },
            title: tr('work.new'),
          }}
        />
        <Stack.Screen
          name="request-overtime"
          options={{
            presentation: 'modal',
            headerShown: true,
            title: tr('overtime.title'),
            headerStyle: { backgroundColor: t.colors.background },
            headerTintColor: t.colors.primary,
            headerTitleStyle: { color: t.colors.text },
            contentStyle: { backgroundColor: t.colors.background },
          }}
        />
        <Stack.Screen
          name="request-time-off"
          options={{
            presentation: 'modal',
            headerShown: true,
            title: tr('timeoff.new'),
            headerStyle: { backgroundColor: t.colors.background },
            headerTintColor: t.colors.primary,
            headerTitleStyle: { color: t.colors.text },
            contentStyle: { backgroundColor: t.colors.background },
          }}
        />
      </Stack>
    </NavigationThemeProvider>
  );
}

/** Route-level error boundary: a crash in one screen never takes down the app. */
export function ErrorBoundary({ error, retry }: ErrorBoundaryProps) {
  return (
    <ThemeProvider>
      <View style={{ flex: 1, justifyContent: 'center' }}>
        <ErrorState onRetry={() => void retry()} message={__DEV__ ? error.message : undefined} />
      </View>
    </ThemeProvider>
  );
}
