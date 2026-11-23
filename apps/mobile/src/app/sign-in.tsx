import { useState } from 'react';
import { Platform, View } from 'react-native';

import { AuthField, AuthLayout } from '@/components/AuthLayout';
import { Button } from '@/components/Button';
import { SegmentedControl } from '@/components/Controls';
import { Text } from '@/components/Text';
import { errorMessage } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useI18n } from '@/i18n';
import { sendPasswordReset, signIn, signUp, switchToDemo } from '@/state/backend';

type Mode = 'sign_in' | 'sign_up';

/** Email and password sign-in for live workspaces (Supabase Auth). */
export default function SignInScreen() {
  const i18n = useI18n();
  const [mode, setMode] = useState<Mode>('sign_in');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const [notice, setNotice] = useState<string | undefined>();
  const redirect = Platform.OS === 'web' && typeof window !== 'undefined' ? window.location.origin : undefined;

  const validEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
  const valid = validEmail && password.length >= 8 && (mode === 'sign_in' || name.trim().length >= 2);

  const run = async (work: () => Promise<void>) => {
    setBusy(true);
    setError(undefined);
    setNotice(undefined);
    try {
      await work();
      haptics.success();
    } catch (e) {
      haptics.error();
      setError(errorMessage(e, i18n.t('common.errorBody')));
    } finally {
      setBusy(false);
    }
  };

  const submit = () =>
    run(async () => {
      if (mode === 'sign_in') await signIn(email, password);
      else if (await signUp(name, email, password, redirect)) setNotice(i18n.t('auth.confirmEmail', { email: email.trim() }));
    });

  return (
    <AuthLayout
      title={i18n.t(mode === 'sign_in' ? 'auth.signInTitle' : 'auth.signUpTitle')}
      subtitle={i18n.t('auth.subtitle')}
      footer={
        <>
          <Button title={i18n.t('auth.tryDemo')} variant="plain" icon="sparkles" onPress={switchToDemo} />
          <Text variant="caption" color="textTertiary" align="center">
            {i18n.t('auth.demoHint')}
          </Text>
        </>
      }
    >
      <SegmentedControl
        segments={[
          { value: 'sign_in', label: i18n.t('auth.signIn') },
          { value: 'sign_up', label: i18n.t('auth.createAccount') },
        ]}
        value={mode}
        onChange={(m) => {
          setMode(m);
          setError(undefined);
          setNotice(undefined);
        }}
      />
      {mode === 'sign_up' && <AuthField label={i18n.t('auth.fullName')} value={name} onChangeText={setName} autoComplete="name" textContentType="name" placeholder="Ana Dela Cruz" />}
      <AuthField
        label={i18n.t('auth.email')}
        value={email}
        onChangeText={setEmail}
        autoCapitalize="none"
        autoComplete="email"
        keyboardType="email-address"
        textContentType="emailAddress"
        placeholder="you@company.com"
      />
      <AuthField
        label={i18n.t('auth.password')}
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        autoComplete={mode === 'sign_in' ? 'current-password' : 'new-password'}
        textContentType={mode === 'sign_in' ? 'password' : 'newPassword'}
        placeholder={i18n.t('auth.passwordHint')}
        onSubmitEditing={() => valid && void submit()}
      />
      {error !== undefined && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {error}
        </Text>
      )}
      {notice !== undefined && (
        <Text variant="footnote" color="success" accessibilityRole="alert">
          {notice}
        </Text>
      )}
      <Button title={i18n.t(mode === 'sign_in' ? 'auth.signIn' : 'auth.createAccount')} onPress={() => void submit()} disabled={!valid} loading={busy} />
      {mode === 'sign_in' && (
        <View style={{ alignItems: 'center' }}>
          <Button
            title={i18n.t('auth.forgot')}
            variant="plain"
            size="small"
            disabled={!validEmail || busy}
            onPress={() =>
              void run(async () => {
                await sendPasswordReset(email, redirect);
                setNotice(i18n.t('auth.resetSent', { email: email.trim() }));
              })
            }
          />
        </View>
      )}
    </AuthLayout>
  );
}
