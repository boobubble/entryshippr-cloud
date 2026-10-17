import { describe, it, expect } from 'vitest';
import { paymentError, paymentRows } from '@/lib/payment-errors';

describe('Payment query results', () => {
  it('returns empty records only from successful reads', () => {
    expect(paymentRows({ data: [], error: null }, 'Payment history')).toEqual([]);
    expect(() => paymentRows({ data: null, error: null }, 'Payment history')).toThrow();
  });
  it('never hides an error behind empty or stale data', () => {
    expect(() => paymentRows({ data: [], error: { code: '42501' } }, 'Payment history')).toThrow();
    expect(() => paymentRows({ data: [{ id: 'old' }], error: { status: 500 } }, 'Payment history')).toThrow();
  });
  it.each(['42P01','42703','PGRST202','PGRST205'])('classifies missing DEV setup %s', code => {
    expect(paymentError({ code }, 'Payment history').message).toContain('DEV database setup');
  });
  it.each([{ code: '42501' },{ status: 403 }])('classifies permission failure %o', error => {
    expect(paymentError(error, 'Payment history').message).toContain('permission');
  });
  it.each([{ code: 'PGRST301' },{ code: 'PGRST303' },{ status: 401 }])('classifies expired sign-in %o', error => {
    expect(paymentError(error, 'Payment history').message).toContain('sign in');
  });
  it('does not report network/service failures as missing setup or expose raw provider details', () => {
    const message = paymentError({ message: 'private provider detail', status: 503 }, 'Payment history').message;
    expect(message).not.toContain('DEV');
    expect(message).not.toContain('private provider detail');
    expect(message).toContain('try again');
  });
});