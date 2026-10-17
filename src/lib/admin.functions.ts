import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
export const adminQuerySchema = z.object({ token: z.string().min(20).max(8000), page: z.number().int().min(0).max(100000), search: z.string().trim().max(100), plan: z.enum(['all','standard','unlimited']), status: z.enum(['all','paid','trial','expired']) });
export const getAdminSellers = createServerFn({ method: 'POST' }).inputValidator(adminQuerySchema).handler(async ({ data }) => {
  const { authenticatedClient, dbError } = await import('./external-auth.server');
  const { client } = await authenticatedClient(data.token, true);
  let query = client.from('profiles').select('*', { count: 'exact' }).order('created_at', { ascending: false }).order('id');
  // Strip PostgREST operator punctuation; never interpolate arbitrary filter syntax.
  const search = data.search.replace(/[^\p{L}\p{N}\s@._+-]/gu, '').replace(/[%_]/g, '');
  if (search) query = query.or(`business_name.ilike.*${search}*,email.ilike.*${search}*`);
  if (data.plan !== 'all') query = query.eq('plan', data.plan);
  const now = new Date().toISOString();
  if (data.status === 'paid') query = query.not('plan','is',null).gt('plan_expires_at', now);
  if (data.status === 'trial') query = query.gt('trial_ends_at', now).or(`plan.is.null,plan_expires_at.is.null,plan_expires_at.lte.${now}`);
  if (data.status === 'expired') query = query.lte('trial_ends_at', now).or(`plan.is.null,plan_expires_at.is.null,plan_expires_at.lte.${now}`);
  const result = await query.range(data.page * 20, data.page * 20 + 19);
  dbError(result.error); return { rows: result.data || [], count: result.count || 0 };
});
export const auditedAdminAction = createServerFn({ method: 'POST' })
  .inputValidator(z.object({ token: z.string().min(20).max(8000), userId: z.string().uuid(), action: z.enum(['extend_trial','grant_plan','revoke']), plan: z.enum(['standard','unlimited']).nullable(), reason: z.string().trim().min(3).max(1000) }))
  .handler(async ({ data }) => {
    const { authenticatedClient, dbError } = await import('./external-auth.server');
    const { client } = await authenticatedClient(data.token, true);
    const result = await client.rpc('admin_set_access_audited', { p_user_id: data.userId, p_action: data.action, p_plan: data.plan, p_reason: data.reason });
    dbError(result.error); return { ok: true };
  });
