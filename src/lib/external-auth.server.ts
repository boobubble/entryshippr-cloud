import { setResponseHeader } from '@tanstack/react-start/server';
import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './supabase';
import { providerError } from './provider-errors';
export function externalClient(token?: string) {
  return createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (input, init) => {
      const headers = new Headers(init?.headers);
      headers.set('apikey', SUPABASE_PUBLISHABLE_KEY);
      if (token) headers.set('Authorization', `Bearer ${token}`);
      else headers.delete('Authorization');
      return fetch(input, { ...init, headers });
    } },
  });
}
export async function authenticatedClient(token: string, admin = false) {
  setResponseHeader('Cache-Control', 'no-store');
  if (typeof token !== 'string' || token.length < 20 || token.length > 8000) throw new Error('Please sign in again.');
  const client = externalClient(token);
  const { data, error } = await client.auth.getUser(token).catch(() => { throw providerError({}, 'Sign-in check'); });
  if (error || !data.user) throw new Error('Please sign in again.');
  if (admin) {
    const role = await client.rpc('is_admin').then(result => result, () => { throw new Error('Admins only.'); });
    if (role.error || role.data !== true) throw new Error('Admins only.');
  }
  return { client, user: data.user };
}
export function dbError(error: { message?: string; code?: string } | null) {
  if (!error) return;
  throw providerError(error, 'This feature');
}
