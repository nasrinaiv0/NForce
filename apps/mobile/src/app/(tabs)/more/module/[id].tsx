import { MODULES, type ModuleId } from '@nforce/core';
import { Stack, useLocalSearchParams } from 'expo-router';

import { EmptyState, Screen } from '@/components/Screen';
import type { IconName } from '@/components/Icon';
import { useI18n } from '@/i18n';

const PLANNED: Partial<Record<ModuleId, { phase: string; icon: IconName }>> = {
  people: { phase: 'Phase 4 · HR & Payroll', icon: 'people' },
  payroll: { phase: 'Phase 4 · HR & Payroll', icon: 'payroll' },
  crm: { phase: 'Phase 5 · CRM', icon: 'crm' },
  reports: { phase: 'Phase 6 · Enterprise analytics', icon: 'reports' },
  admin: { phase: 'Phase 6 · Enterprise admin', icon: 'admin' },
};

const isModuleId = (v: unknown): v is ModuleId => typeof v === 'string' && MODULES.some((m) => m.id === v);

/** Roadmap placeholder for modules whose permissions exist but UI is planned. */
export default function ModuleScreen() {
  const { t } = useI18n();
  const { id } = useLocalSearchParams<{ id: string }>();
  const moduleId = isModuleId(id) ? id : undefined;
  const plan = moduleId !== undefined ? PLANNED[moduleId] : undefined;
  return (
    <Screen>
      <Stack.Screen options={{ title: moduleId !== undefined ? t(`module.${moduleId}`) : '' }} />
      <EmptyState
        icon={plan?.icon ?? 'sparkles'}
        title={t('module.plannedTitle', { phase: plan?.phase ?? 'a later phase' })}
        body={t('module.plannedBody')}
      />
    </Screen>
  );
}
