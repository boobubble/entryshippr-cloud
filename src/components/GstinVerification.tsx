import { useEffect, useRef, useState } from 'react';
import { CheckCircle2, Loader2, ShieldCheck, TriangleAlert } from 'lucide-react';
import { useServerFn } from '@tanstack/react-start';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { accessToken } from '@/lib/supabase';
import { verifyGstin } from '@/lib/gstin.functions';
import { clientGstinPatch, normalizeGstin, registrationState, validGstin, type GstinResult, type Registration } from '@/lib/gstin';

export function GstinVerification({ value, onChange, onApply, lookup }: {
  value: string; onChange: (v: string) => void; onApply: (patch: ReturnType<typeof clientGstinPatch>) => void;
  lookup?: (gstin: string) => Promise<GstinResult>;
}) {
  const verify = useServerFn(verifyGstin);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<GstinResult | null>(null);
  const [confirming, setConfirming] = useState(false);
  const sequence = useRef(0);
  useEffect(() => { sequence.current++; setBusy(false); setResult(null); setConfirming(false); return () => { sequence.current++; }; }, [value]);
  async function run() {
    const id = ++sequence.current;
    const gstin = normalizeGstin(value);
    if (!validGstin(gstin)) { setResult({ ok: false, category: 'invalid', message: 'Enter a valid 15-character GSTIN with a correct checksum.', retryable: false }); return; }
    setBusy(true); setResult(null); setConfirming(false);
    try {
      const r = await (lookup ? lookup(gstin) : verify({ data: { gstin, token: await accessToken() } }));
      if (id === sequence.current) setResult(r);
    } catch {
      if (id === sequence.current) setResult({ ok: false, category: 'unavailable', message: 'GSTIN verification could not be completed. Check your sign-in and try again.', retryable: true });
    } finally { if (id === sequence.current) setBusy(false); }
  }
  const registration: Registration | undefined = result?.ok ? result.registration : undefined;
  const patch = registration ? clientGstinPatch(registration) : {};
  return <div className="space-y-2">
    <div className="flex flex-wrap gap-2">
      <Input aria-label="GSTIN" className="min-w-0 flex-1 uppercase" value={value} maxLength={15} onChange={e => onChange(e.target.value)} />
      <Button type="button" variant="outline" disabled={busy || !value.trim()} onClick={run}>
        {busy ? <Loader2 className="animate-spin motion-reduce:animate-none" /> : <ShieldCheck />} {busy ? 'Verifying…' : 'Verify GSTIN'}
      </Button>
    </div>
    {result && !result.ok && <div role="alert" className="space-y-2 text-sm text-destructive"><p>{result.message}</p>{result.retryable && <Button type="button" variant="outline" size="sm" onClick={run}>Retry verification</Button>}</div>}
    {registration && <div className="space-y-2 border-l-2 border-border pl-3 text-sm" aria-live="polite">
      <p className="flex items-center gap-2 font-medium">{registration.status.toLowerCase() === 'active' ? <CheckCircle2 className="size-4" /> : <TriangleAlert className="size-4" />}{registrationState(registration.status)}</p>
      <dl className="space-y-1 break-words">
        {Object.entries({ 'Legal name': registration.legal_name, 'Trade name': registration.trade_name, 'Taxpayer type': registration.taxpayer_type,
          'Registered': registration.registration_date, 'Cancelled': registration.cancellation_date, 'Address': registration.address,
          'PIN code': registration.pincode || registration.address_details?.pincode }).filter(([,v]) => v).map(([label,v]) => <div key={label}><dt className="inline text-muted-foreground">{label}: </dt><dd className="inline">{v}</dd></div>)}
      </dl>
      {!result?.ok || result.sandbox ? <p>Sandbox result — cannot be applied to a client.</p> : confirming ? <div className="space-y-2">
        <p>Replace the supplied client details with these verified values?</p>
        <dl>{Object.entries(patch).map(([k,v]) => <div key={k} className="break-words"><dt className="inline capitalize">{k}: </dt><dd className="inline">{v}</dd></div>)}</dl>
        <div className="flex flex-wrap gap-2"><Button type="button" onClick={() => { onApply(patch); setConfirming(false); }}>Confirm replacement</Button><Button type="button" variant="outline" onClick={() => setConfirming(false)}>Keep my details</Button></div>
      </div> : <Button type="button" variant="outline" onClick={() => setConfirming(true)}>Apply verified details</Button>}
    </div>}
  </div>;
}