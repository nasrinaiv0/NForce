import AsyncStorage from '@react-native-async-storage/async-storage';
import { randomUUID } from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';

import { createSecureSessionStorage } from './secureSessionStorage';

const options: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
async function available() {
  if (!(await SecureStore.isAvailableAsync())) throw new Error('Secure session storage unavailable.');
}

export const nativeSessionStorage = createSecureSessionStorage({
  get: async (key) => { await available(); return SecureStore.getItemAsync(key, options); },
  set: async (key, value) => { await available(); await SecureStore.setItemAsync(key, value, options); },
  remove: async (key) => { await available(); await SecureStore.deleteItemAsync(key, options); },
}, randomUUID, async (key) => {
  // Delete legacy insecure Supabase storage; never read or migrate its tokens.
  await AsyncStorage.removeItem(key);
});
