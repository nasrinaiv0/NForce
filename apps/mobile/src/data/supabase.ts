import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { Platform } from 'react-native';

import './polyfills';

/**
 * Supabase connection. Both values are public by design: the URL and the
 * publishable (anon) key only allow what row-level security and the
 * SECURITY DEFINER functions permit for the signed-in user. Never put a
 * secret or service-role key here.
 *
 * Set them as EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_KEY (in
 * `apps/mobile/.env.local` for development, and in the hosting provider's
 * environment for web builds). When either is missing the app runs the demo.
 */
export const SUPABASE_URL = (process.env.EXPO_PUBLIC_SUPABASE_URL ?? '').trim();
export const SUPABASE_KEY = (process.env.EXPO_PUBLIC_SUPABASE_KEY ?? '').trim();
export const liveConfigured = /^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(SUPABASE_URL) && SUPABASE_KEY.length > 20;

let client: SupabaseClient | undefined;

export function supabase(): SupabaseClient {
  if (!liveConfigured) throw new Error('Supabase is not configured.');
  client ??= createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: {
      // P0: do not write authentication tokens to unencrypted persistent storage.
      // Reauthentication is required after restart until secure persistence is reviewed.
      persistSession: false,
      autoRefreshToken: true,
      // Email confirmation links land on the web app with the session in the URL.
      detectSessionInUrl: Platform.OS === 'web',
    },
  });
  return client;
}
