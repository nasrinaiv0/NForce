import { StyleSheet, View } from 'react-native';

import type { ApprovalStepView } from '@/data/types';
import { useTheme } from '@/design/theme';
import type { I18n } from '@/i18n';
import { Avatar } from './Display';
import { Icon } from './Icon';
import { Text } from './Text';

/** Compact "who approves this" line: Supervisor → Manager (final). */
export function ApproverChain({ steps, i18n }: { steps: readonly ApprovalStepView[]; i18n: I18n }) {
  const t = useTheme();
  return (
    <View style={styles.row} accessible accessibilityLabel={`${i18n.t('approvals.routeTo')}: ${steps.map((s) => `${i18n.t(`approvals.level.${s.level}`)} ${s.approver.name}`).join(', ')}`}>
      <Icon name="hierarchy" size={15} color={t.colors.textSecondary} />
      {steps.map((s, i) => (
        <View key={`${s.level}-${i}`} style={styles.row}>
          {i > 0 && <Icon name="chevron" size={11} color={t.colors.textTertiary} />}
          <Avatar initials={s.approver.initials} hue={s.approver.hue} size={22} />
          <Text variant="footnote" numberOfLines={1}>
            {s.approver.name.split(' ')[0]}
            <Text variant="caption" color="textSecondary">{` · ${i18n.t(`approvals.level.${s.level}`)}`}</Text>
          </Text>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap' },
});
