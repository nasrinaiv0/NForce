import type { createSecureSessionStorage } from './secureSessionStorage';

// Web and non-native environments deliberately retain memory-only sessions.
export const nativeSessionStorage: ReturnType<typeof createSecureSessionStorage> | undefined = undefined;
