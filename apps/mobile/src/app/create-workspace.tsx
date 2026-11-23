import { useState } from 'react';

import { AuthField, AuthLayout } from '@/components/AuthLayout';
import { Button } from '@/components/Button';
import { Text } from '@/components/Text';
import { errorMessage } from '@/data/queries';
import { haptics } from '@/design/haptics';
import { useI18n } from '@/i18n';
import { createWorkspace, signOut, switchToDemo, useBackend } from '@/state/backend';

const deviceTimeZone = (): string => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Manila';
  } catch {
    return 'Asia/Manila';
  }
};

/**
 * First run for a signed-in person with no workspace: create one (they become
 * its owner), or wait to be added by an existing organization.
 */
export default function CreateWorkspaceScreen() {
  const i18n = useI18n();
  const email = useBackend((s) => s.email ?? '');
  const loadError = useBackend((s) => s.error);
  const [name, setName] = useState('');
  const [title, setTitle] = useState('');
  const [timeZone, setTimeZone] = useState(deviceTimeZone);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const valid = name.trim().length >= 2 && timeZone.trim().length > 0;

  const submit = async () => {
    setBusy(true);
    setError(undefined);
    try {
      await createWorkspace(name, timeZone.trim(), title);
      haptics.success();
    } catch (e) {
      haptics.error();
      setError(errorMessage(e, i18n.t('common.errorBody')));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout
      title={i18n.t('auth.workspaceTitle')}
      subtitle={i18n.t('auth.workspaceSubtitle', { email })}
      footer={
        <>
          <Button title={i18n.t('auth.signOut')} variant="plain" icon="logout" onPress={() => void signOut()} />
          <Button title={i18n.t('auth.tryDemo')} variant="plain" icon="sparkles" onPress={switchToDemo} />
        </>
      }
    >
      <AuthField label={i18n.t('auth.orgName')} value={name} onChangeText={setName} placeholder="Northwind Logistics" autoComplete="organization" />
      <AuthField label={i18n.t('auth.jobTitle')} value={title} onChangeText={setTitle} placeholder={i18n.t('auth.jobTitlePlaceholder')} />
      <AuthField label={i18n.t('auth.timeZone')} value={timeZone} onChangeText={setTimeZone} autoCapitalize="none" placeholder="Asia/Manila" />
      <Text variant="caption" color="textSecondary">
        {i18n.t('auth.workspaceHint')}
      </Text>
      {(error ?? loadError) !== undefined && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {error ?? loadError}
        </Text>
      )}
      <Button title={i18n.t('auth.createWorkspace')} onPress={() => void submit()} disabled={!valid} loading={busy} />
    </AuthLayout>
  );
}
