import type { ReactNode } from 'react';
import { Image, KeyboardAvoidingView, Platform, ScrollView, StyleSheet, TextInput, View, type TextInputProps } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useTheme } from '@/design/theme';
import { Card } from './Surface';
import { Text } from './Text';

/** Centered brand card used by sign-in and workspace setup. */
export function AuthLayout({ title, subtitle, children, footer }: { title: string; subtitle?: string; children: ReactNode; footer?: ReactNode }) {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: t.colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <ScrollView
        contentContainerStyle={[styles.scroll, { paddingTop: insets.top + 32, paddingBottom: insets.bottom + 32, paddingHorizontal: t.space.lg }]}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.column}>
          <View style={[styles.brand, { gap: t.space.sm }]}>
            <Image source={require('../../assets/brand/logo.png')} style={styles.logo} resizeMode="contain" accessibilityLabel="NForce" />
            <Text variant="title" align="center" accessibilityRole="header">
              {title}
            </Text>
            {subtitle !== undefined && (
              <Text variant="subhead" color="textSecondary" align="center">
                {subtitle}
              </Text>
            )}
          </View>
          <Card style={{ gap: t.space.lg, padding: t.space.xl }}>{children}</Card>
          {footer !== undefined && <View style={{ gap: t.space.sm, alignItems: 'center' }}>{footer}</View>}
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

/** Labelled text field for auth forms. */
export function AuthField({ label, ...input }: { label: string } & TextInputProps) {
  const t = useTheme();
  return (
    <View style={{ gap: 6 }}>
      <Text variant="footnote" color="textSecondary" weight="600">
        {label}
      </Text>
      <TextInput
        {...input}
        accessibilityLabel={label}
        placeholderTextColor={t.colors.textTertiary}
        style={[t.type.body, styles.input, { color: t.colors.text, backgroundColor: t.colors.fill, borderRadius: t.shape.control }]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: { flexGrow: 1, justifyContent: 'center', alignItems: 'center' },
  column: { width: '100%', maxWidth: 420, gap: 20 },
  brand: { alignItems: 'center' },
  logo: { width: 64, height: 64, marginBottom: 4 },
  input: { minHeight: 48, paddingHorizontal: 14, paddingVertical: 10 },
});
