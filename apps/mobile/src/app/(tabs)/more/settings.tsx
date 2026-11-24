import { ROLE_TEMPLATES } from '@nforce/core';
import Constants from 'expo-constants';
import { router } from 'expo-router';
import { StyleSheet, View } from 'react-native';
import { Chip, Toggle } from '@/components/Controls';
import { ListRow, ListSection } from '@/components/Surface';
import { Screen } from '@/components/Screen';
import { Text } from '@/components/Text';
import { resetSession } from '@/data/queries';
import { liveConfigured } from '@/data/supabase';
import { useTheme } from '@/design/theme';
import { LOCALES, useI18n } from '@/i18n';
import { activeWorkspace, signOut, switchToLive, useBackend } from '@/state/backend';
import { setPreference, usePreference, type Preferences } from '@/state/preferences';

export default function SettingsScreen() {
  const t=useTheme();
  const {t:tr}=useI18n();
  const locale = usePreference('locale');
  const haptics = usePreference('haptics');
  const reduceMotion = usePreference('reduceMotion');
  const persona = usePreference('persona');
  const backend = usePreference('backend');
  const live = liveConfigured && backend === 'live';
  const email = useBackend((s) => s.email ?? '');
  const workspaceList = useBackend((s) => s.workspaces);
  const workspaces = workspaceList ?? [];
  const current = useBackend((s) => activeWorkspace(s)?.organizationId);

  const switchPersona = (role: Preferences['persona']) => {
    if (role === persona) return;
    setPreference('persona', role);
    void resetSession();
  };

  return <Screen>
      <ListSection title={tr('more.preferences')}>
        <ListRow
          title={tr('customize.title')}
          subtitle={tr('customize.subtitle')}
          icon="palette"
          iconTint="#AF52DE"
          onPress={() => router.push('/more/customize')}
        />
        <Field label={tr('more.language')}>
          <View style={styles.chips}>
            <Chip label={tr('more.language.system')} selected={locale === 'system'} onPress={() => setPreference('locale', 'system')} />
            {LOCALES.map((l) => (
              <Chip key={l.id} label={l.native} selected={locale === l.id} onPress={() => setPreference('locale', l.id)} />
            ))}
          </View>
        </Field>
        <ListRow
          title={tr('more.haptics')}
          icon="hand"
          iconTint="#FF3B30"
          trailing={<Toggle value={haptics} onValueChange={(v) => setPreference('haptics', v)} label={tr('more.haptics')} />}
        />
        <ListRow
          title={tr('more.reduceMotion')}
          icon="motion"
          iconTint="#007AFF"
          trailing={<Toggle value={reduceMotion} onValueChange={(v) => setPreference('reduceMotion', v)} label={tr('more.reduceMotion')} />}
          last
        />
      </ListSection>

      {live ? (
        <ListSection title={tr('more.account')}>
          <ListRow title={tr('more.signedInAs', { email })} icon="person" iconTint="#007AFF" />
          {workspaces.length > 1 && (
            <Field label={tr('more.switchWorkspace')}>
              <View style={styles.chips}>
                {workspaces.map((w) => (
                  <Chip key={w.organizationId} label={w.name} selected={current === w.organizationId} onPress={() => setPreference('workspaceId', w.organizationId)} />
                ))}
              </View>
            </Field>
          )}
          <ListRow title={tr('auth.signOut')} icon="logout" iconTint="#FF3B30" onPress={() => void signOut()} last />
        </ListSection>
      ) : (
        <>
          {liveConfigured && (
            <ListSection footer={tr('more.liveSignInHint')}>
              <ListRow title={tr('more.liveSignIn')} icon="login" iconTint="#34C759" onPress={switchToLive} last />
            </ListSection>
          )}
          <ListSection title={tr('more.persona')} footer={tr('more.personaFooter')}>
            <View style={[styles.chips, { padding: t.space.lg }]}>
              {ROLE_TEMPLATES.map((r) => (
                <Chip key={r} label={tr(`role.${r}`)} selected={persona === r} onPress={() => switchPersona(r)} />
              ))}
            </View>
          </ListSection>
        </>
      )}

      <ListSection>
        <ListRow title={tr('more.about')} icon="info" iconTint="#8E8E93" value={tr('more.version', { version: Constants.expoConfig?.version ?? '0.1.0' })} />
        <ListRow title={tr('more.privacy')} icon="shield" iconTint="#34C759" last />
      </ListSection>

  </Screen>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  const t = useTheme();
  return (
    <View
      style={{
        padding: t.space.lg,
        gap: t.space.sm,
        borderBottomWidth: t.flavor === 'ios' ? StyleSheet.hairlineWidth : 0,
        borderBottomColor: t.colors.separator,
      }}
    >
      <Text variant="subhead" color="textSecondary">
        {label}
      </Text>
      {children}
    </View>
  );
}


const styles=StyleSheet.create({chips:{flexDirection:'row',flexWrap:'wrap',gap:8}});
