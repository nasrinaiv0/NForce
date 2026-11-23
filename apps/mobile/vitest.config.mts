import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Unit tests for framework-free app modules (data layer, i18n). UI is verified
// with typecheck, lint and rendered previews.
export default defineConfig({
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  test: { include: ['test/**/*.test.ts'], environment: 'node' },
});
