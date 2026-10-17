type PaymentError = { code?: string; message?: string; status?: number };

export function paymentError(error: PaymentError, operation: string): Error {
  if (['42P01', '42703', 'PGRST202', 'PGRST205'].includes(error.code || '')) {
    return new Error(`${operation} is awaiting the reviewed DEV database setup.`);
  }
  if (error.code === '42501' || error.status === 403) return new Error(`You do not have permission to access ${operation.toLowerCase()}.`);
  if (error.code === 'PGRST301' || error.code === 'PGRST303' || error.status === 401) return new Error('Please sign in again.');
  return new Error(`Could not load ${operation.toLowerCase()}. Please try again.`);
}

export function paymentRows<T>(result: { data: T[] | null; error: PaymentError | null }, operation: string): T[] {
  if (result.error) throw paymentError(result.error, operation);
  if (!result.data) throw new Error(`Could not load ${operation.toLowerCase()}. Please try again.`);
  return result.data;
}