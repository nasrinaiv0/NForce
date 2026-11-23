import { QueryClientProvider } from '@tanstack/react-query';
import { DarkTheme, DefaultTheme, Stack, ThemeProvider as NavigationThemeProvider, router, useSegments, type ErrorBoundaryProps } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import * as SystemUI from 'expo-system-ui';
import { useEffect, useMemo } from 'react';
import { View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { ErrorState } from '@/components/Screen';
import { queryClient, resetSession } from '@/data/queries';
import { liveConfigured } from '@/data/supabase';
import { ThemeProvider, useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { activeWorkspace, backendStore, startBackend, useBackend } from '@/state/backend';
import { hydratePreferences, preferencesStore, usePreference, usePreferencesHydrated } from '@/state/preferences';

void SplashScreen.preventAutoHideAsync().catch(() => undefined);

export default function RootLayout() {
  useEffect(() => {
    void hydratePreferences().then(startBackend);
  }, []);
  useEffect(() => {
    // Whenever the account, workspace or backend changes, drop all cached data.
    let last = '';
    const check = () => {
      const s = backendStore.get();
      const key = `${preferencesStore.get().backend}|${s.userId ?? ''}|${activeWorkspace(s)?.organizationId ?? ''}`;
      if (key !== last) {
        last = key;
        void resetSession();
      }
    };
    const a = backendStore.subscribe(check);
    const b = preferencesStore.subscribe(check);
    return () => {
      a();
      b();
    };
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
  const backend = usePreference('backend');
  const auth = useBackend((s) => s.auth);
  const workspaceCount = useBackend((s) => s.workspaces?.length);
  const live = liveConfigured && backend === 'live';
  const needsSignIn = live && auth === 'signed_out';
  const needsWorkspace = live && auth === 'signed_in' && workspaceCount === 0;
  const resolving = live && (auth === 'unknown' || (auth === 'signed_in' && workspaceCount === undefined));
  const inApp = !needsSignIn && !needsWorkspace;
  const segments = useSegments();
  const at = segments[0] as string | undefined;

  // Send people to sign-in or workspace setup (and back) as their state changes.
  useEffect(() => {
    if (!hydrated || resolving) return;
    if (needsSignIn && at !== 'sign-in') router.replace('/sign-in');
    else if (needsWorkspace && at !== 'create-workspace') router.replace('/create-workspace');
    else if (inApp && (at === 'sign-in' || at === 'create-workspace')) router.replace('/');
  }, [hydrated, resolving, needsSignIn, needsWorkspace, inApp, at]);

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

  if (!hydrated || resolving) return <View style={{ flex: 1, backgroundColor: t.colors.background }} />;

  return (
    <NavigationThemeProvider value={navTheme}>
      <StatusBar style={t.scheme === 'dark' ? 'light' : 'dark'} />
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: t.colors.background } }}>
        <Stack.Protected guard={needsSignIn}>
          <Stack.Screen name="sign-in" />
        </Stack.Protected>
        <Stack.Protected guard={needsWorkspace}>
          <Stack.Screen name="create-workspace" />
        </Stack.Protected>
        <Stack.Protected guard={inApp}>
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
            name="employee-form"
            options={{
              presentation: 'modal',
              headerShown: true,
              title: tr('people.form.title.screen'),
              headerStyle: { backgroundColor: t.colors.background },
              headerTintColor: t.colors.primary,
              headerTitleStyle: { color: t.colors.text },
              contentStyle: { backgroundColor: t.colors.background },
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
        </Stack.Protected>
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
