import { UserId, searchItems, type RoleTemplate } from '@nforce/core';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';

import { Button } from '@/components/Button';
import { Chip } from '@/components/Controls';
import { Avatar } from '@/components/Display';
import { SearchField } from '@/components/ListToolbar';
import { LoadingBlock, Screen } from '@/components/Screen';
import { Card } from '@/components/Surface';
import { Text } from '@/components/Text';
import { Touchable } from '@/components/Touchable';
import { errorMessage, useCreateEmployee, useDirectory, useProfile, useSession, useUpdateEmployee } from '@/data/queries';
import { liveConfigured } from '@/data/supabase';
import { haptics } from '@/design/haptics';
import { useTheme } from '@/design/theme';
import { useI18n } from '@/i18n';
import { usePreference } from '@/state/preferences';

/**
 * Add or edit an employee. Role choices come from the server and include only
 * roles the current user may grant (no privilege escalation).
 */
export default function EmployeeForm() {
  const params = useLocalSearchParams<{ id?: string }>();
  const id = typeof params.id === 'string' && params.id.length > 0 ? UserId(params.id) : undefined;
  const directory = useDirectory();
  const profile = useProfile(id ?? UserId('none'), id !== undefined);
  if (directory.data === undefined || (id !== undefined && profile.data === undefined)) {
    return (
      <Screen>
        <LoadingBlock rows={4} height={60} />
      </Screen>
    );
  }
  return <Form id={id} initial={id !== undefined ? profile.data : undefined} />;
}

function Form({ id, initial }: { id?: UserId; initial?: ReturnType<typeof useProfile>['data'] }) {
  const t = useTheme();
  const i18n = useI18n();
  const session = useSession();
  const directory = useDirectory();
  const create = useCreateEmployee();
  const update = useUpdateEmployee();
  const editing = id !== undefined;
  const isSelf = editing && session.data?.user.id === id;
  const [name, setName] = useState(initial?.person.name ?? '');
  const [title, setTitle] = useState(initial?.person.title ?? '');
  const [department, setDepartment] = useState(initial?.department ?? 'Operations');
  const [team, setTeam] = useState<string | undefined>(initial?.teamName);
  const [managerId, setManagerId] = useState<UserId | undefined>(initial?.manager?.id);
  const [role, setRole] = useState<RoleTemplate>(initial?.role ?? 'staff');
  const [managerSearch, setManagerSearch] = useState('');
  const [email, setEmail] = useState('');
  const backendPref = usePreference('backend');
  const live = liveConfigured && backendPref === 'live';

  const people = useMemo(() => directory.data ?? [], [directory.data]);
  const departments = useMemo(() => [...new Set(people.map((p) => p.department))].sort(), [people]);
  const teams = useMemo(() => [...new Set(people.map((p) => p.teamName).filter((x): x is string => x !== undefined))].sort(), [people]);
  const managers = useMemo(
    () => searchItems(people.filter((p) => p.person.id !== id && p.role !== 'staff'), managerSearch, (p) => [p.person.name, p.person.title]).slice(0, 8),
    [people, managerSearch, id],
  );
  const assignable = session.data?.capabilities.assignableRoles ?? [];
  // Editing: only roles the server says the viewer may give THIS person (none when it has access they lack).
  const roleLocked = editing && initial !== undefined && !initial.access.canChangeRole;
  const roleChoices: RoleTemplate[] = [
    ...new Set<RoleTemplate>([...(editing && initial !== undefined ? [initial.role, ...initial.access.assignableRoles] : assignable)]),
  ];
  const busy = create.isPending || update.isPending;
  const error = create.error ?? update.error;
  // The top of the organization has no manager; everyone else needs one.
  const needsManager = !editing || initial?.manager !== undefined;
  const emailOk = !live || editing || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
  const valid = name.trim().length > 1 && title.trim().length > 1 && (managerId !== undefined || !needsManager) && emailOk;

  const save = () => {
    if (!valid) return;
    const done = { onSuccess: () => { haptics.success(); router.back(); }, onError: () => haptics.error() };
    if (editing && id !== undefined) {
      update.mutate({ id, patch: { title, ...(managerId !== undefined ? { managerId } : {}), ...(role !== initial?.role ? { role } : {}) } }, done);
    } else {
      if (managerId === undefined) return;
      create.mutate({ name, title, role, managerId, department, ...(team !== undefined ? { teamName: team } : {}), ...(live ? { email: email.trim() } : {}) }, done);
    }
  };

  const input = [t.type.body, styles.input, { color: t.colors.text, backgroundColor: t.colors.surface, borderRadius: t.shape.control }];
  return (
    <Screen maxWidth={720}>
      <Field label={i18n.t('people.form.name')}>
        <TextInput value={name} onChangeText={setName} editable={!editing} placeholder={i18n.t('people.form.namePlaceholder')} placeholderTextColor={t.colors.textTertiary} accessibilityLabel={i18n.t('people.form.name')} style={[input, editing && { opacity: 0.6 }]} />
      </Field>
      {live && !editing && (
        <Field label={i18n.t('people.form.email')}>
          <TextInput
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            keyboardType="email-address"
            autoComplete="email"
            placeholder="name@company.com"
            placeholderTextColor={t.colors.textTertiary}
            accessibilityLabel={i18n.t('people.form.email')}
            style={input}
          />
          <Text variant="caption" color="textTertiary">
            {i18n.t('people.form.emailHint')}
          </Text>
        </Field>
      )}
      <Field label={i18n.t('people.form.title')}>
        <TextInput value={title} onChangeText={setTitle} placeholder={i18n.t('people.form.titlePlaceholder')} placeholderTextColor={t.colors.textTertiary} accessibilityLabel={i18n.t('people.form.title')} style={input} />
      </Field>
      {!editing && (
        <>
          <Field label={i18n.t('people.department')}>
            <View style={styles.chips}>
              {departments.map((d) => (
                <Chip key={d} label={d} selected={department === d} onPress={() => setDepartment(d)} />
              ))}
            </View>
          </Field>
          <Field label={i18n.t('team.col.team')}>
            <View style={styles.chips}>
              <Chip label={i18n.t('team.noTeam')} selected={team === undefined} onPress={() => setTeam(undefined)} />
              {teams.map((x) => (
                <Chip key={x} label={x} selected={team === x} onPress={() => setTeam(x)} />
              ))}
            </View>
          </Field>
        </>
      )}
      <Field label={i18n.t('people.form.manager')}>
        <SearchField value={managerSearch} onChange={setManagerSearch} placeholder={i18n.t('people.form.managerSearch')} />
        <Card padded={false}>
          {managers.map((m, idx) => {
            const selected = managerId === m.person.id;
            return (
              <Touchable
                key={m.person.id}
                onPress={() => setManagerId(m.person.id)}
                feedback="highlight"
                accessibilityRole="radio"
                accessibilityState={{ selected }}
                accessibilityLabel={`${m.person.name}, ${m.person.title}`}
                style={[styles.managerRow, { paddingHorizontal: t.space.lg }, idx < managers.length - 1 && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.colors.separator }, selected && { backgroundColor: t.colors.primaryContainer }]}
              >
                <Avatar initials={m.person.initials} hue={m.person.hue} size={30} />
                <View style={{ flex: 1 }}>
                  <Text variant="subhead" weight={selected ? '700' : '500'}>
                    {m.person.name}
                  </Text>
                  <Text variant="caption" color="textSecondary">
                    {m.person.title}
                  </Text>
                </View>
              </Touchable>
            );
          })}
        </Card>
      </Field>
      <Field label={i18n.t('people.role')}>
        {isSelf ? (
          <Text variant="footnote" color="textSecondary">
            {i18n.t('people.form.selfRole')}
          </Text>
        ) : roleLocked ? (
          <Text variant="footnote" color="textSecondary">
            {i18n.t(`role.${role}`)} · {i18n.t('people.form.roleLocked')}
          </Text>
        ) : (
          <>
            <View style={styles.chips}>
              {roleChoices.map((r) => (
                <Chip key={r} label={i18n.t(`role.${r}`)} selected={role === r} onPress={() => setRole(r)} />
              ))}
            </View>
            <Text variant="caption" color="textTertiary">
              {i18n.t('people.form.roleHint')}
            </Text>
          </>
        )}
      </Field>
      {error !== null && (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {errorMessage(error, i18n.t('common.errorBody'))}
        </Text>
      )}
      <Button title={i18n.t(editing ? 'common.save' : 'people.form.add')} icon={editing ? 'check' : 'add'} size="large" onPress={save} disabled={!valid} loading={busy} />
    </Screen>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  const t = useTheme();
  return (
    <View style={{ gap: t.space.sm }}>
      <Text variant="footnote" color="textSecondary" weight="600" style={{ textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  input: { minHeight: 48, paddingHorizontal: 14, paddingVertical: 10 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  managerRow: { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 52, paddingVertical: 8 },
});
