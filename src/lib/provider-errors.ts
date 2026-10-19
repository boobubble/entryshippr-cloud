type Category = 'setup' | 'permission' | 'authentication' | 'configuration' | 'conflict' | 'unavailable';
const CATEGORIES: Category[] = ['setup', 'permission', 'authentication', 'configuration', 'conflict', 'unavailable'];

function safeStatus(status: unknown) {
  return typeof status === 'number' && Number.isInteger(status) && status >= 100 && status <= 599 ? status : undefined;
}

/**
 * Never retain provider messages, bodies, URLs, headers or request data.
 * `credential: 'server'` marks calls made with server-held keys (database secret key, Razorpay keys):
 * a 401/403 there is a server configuration problem, never a reason to ask the user to sign in again.
 */
export function providerError(
  error: { code?: string | undefined; status?: number | undefined },
  operation = 'Request',
  credential: 'user' | 'server' = 'user',
) {
  let category: Category = ['42P01', '42703', 'PGRST202', 'PGRST205'].includes(error.code || '') ? 'setup'
    : error.code === '42501' || error.status === 403 ? 'permission'
    : ['PGRST301', 'PGRST303'].includes(error.code || '') || error.status === 401 ? 'authentication'
    : error.status === 409 || ['23505', '23514'].includes(error.code || '') ? 'conflict' : 'unavailable';
  if (credential === 'server' && (category === 'authentication' || category === 'permission')) category = 'configuration';
  const messages: Record<Category, string> = {
    setup: `${operation} is awaiting the reviewed DEV database setup.`,
    permission: 'You do not have permission to perform this action.',
    authentication: 'Please sign in again.',
    configuration: `${operation} is not configured correctly on the server. Please contact support.`,
    conflict: 'This request conflicts with the existing submission. Check your details.',
    unavailable: `${operation} could not be completed. Please try again.`,
  };
  return Object.assign(new Error(messages[category]), { category, status: safeStatus(error.status) });
}

/** The user's session token was rejected by the sign-in service. */
export function sessionError(status?: number) {
  return Object.assign(new Error('Please sign in again.'), { category: 'authentication' as const, status: safeStatus(status) });
}

/** Allowlist diagnostics rather than trying to redact arbitrary nested provider objects. */
export function logPaymentFailure(operation: 'webhook-activation' | 'checkout' | 'payment-verification', error: unknown, stage?: string) {
  const e = error && typeof error === 'object' ? error as { category?: unknown; status?: unknown } : {};
  const category = CATEGORIES.includes(String(e.category) as Category) ? String(e.category) : 'unavailable';
  const status = safeStatus(e.status);
  console.error('Payment operation failed', {
    operation,
    ...(stage && /^[a-z-]{1,40}$/.test(stage) ? { stage } : {}),
    ...(status ? { status } : {}),
    category,
  });
}

/** Run one server stage; on failure log only operation, stage, HTTP status and category, then rethrow. */
export async function paymentStage<T>(operation: 'checkout' | 'payment-verification', stage: string, fn: () => Promise<T>): Promise<T> {
  try { return await fn(); } catch (error) { logPaymentFailure(operation, error, stage); throw error; }
}
