/** Never retain provider messages, bodies, URLs, headers or request data. */
export function providerError(error: { code?: string; status?: number }, operation = 'Request') {
  const category = ['42P01', '42703', 'PGRST202', 'PGRST205'].includes(error.code || '') ? 'setup'
    : error.code === '42501' || error.status === 403 ? 'permission'
    : ['PGRST301', 'PGRST303'].includes(error.code || '') || error.status === 401 ? 'authentication'
    : error.status === 409 || ['23505', '23514'].includes(error.code || '') ? 'conflict' : 'unavailable';
  const messages = { setup: `${operation} is awaiting the reviewed DEV database setup.`, permission: 'You do not have permission to perform this action.', authentication: 'Please sign in again.', conflict: 'This request conflicts with the existing submission. Check your details.', unavailable: `${operation} could not be completed. Please try again.` };
  return Object.assign(new Error(messages[category]), { category });
}

/** Allowlist diagnostics rather than trying to redact arbitrary nested provider objects. */
export function logPaymentFailure(operation: 'webhook-activation', error: unknown) {
  const category = error && typeof error === 'object' && 'category' in error &&
    ['setup', 'permission', 'authentication', 'conflict', 'unavailable'].includes(String(error.category))
    ? String(error.category) : 'unavailable';
  console.error('Payment operation failed', { operation, category });
}