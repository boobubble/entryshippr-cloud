import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { supabase, accessToken, PLANS, inr } from '@/lib/supabase';
import { errMsg } from '@/lib/hooks';
import { validateReference } from '@/lib/image-validation';
import { validatePaymentProofBytes } from '@/lib/payment-proof-validation';
import { paymentRows } from '@/lib/payment-errors';
import { submitPaymentProof, paymentProofUrl } from '@/lib/payment-proofs.functions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
export function PaymentProofForm() {
  const [plan,setPlan]=useState<'standard'|'unlimited'>('standard');
  const [reference,setReference]=useState(''); const [file,setFile]=useState<File|null>(null);
  const [busy,setBusy]=useState(false); const request=useRef<string|null>(null); const input=useRef<HTMLInputElement>(null);
  const submit=useServerFn(submitPaymentProof); const proof=useServerFn(paymentProofUrl); const qc=useQueryClient();
  const history=useQuery({queryKey:['payment-submissions'],retry:false,queryFn:async()=>{
    const user=await supabase.auth.getUser(); if(!user.data.user) throw new Error('Please sign in again.');
    const r=await supabase.from('payment_submissions').select('id,reference,status,reason,created_at,submitted_at,payments(plan,amount_paise)').eq('owner_id',user.data.user.id).not('submitted_at','is',null).order('created_at',{ascending:false}).limit(50);
    return paymentRows(r, 'Payment proof submissions');
  }});
  async function save(e:React.FormEvent){ e.preventDefault(); if(busy)return; setBusy(true);
    try{ if(!file)throw new Error('Choose a payment screenshot.'); validateReference(reference); validatePaymentProofBytes(new Uint8Array(await file.arrayBuffer()),file.type);
      if(!request.current)request.current=crypto.randomUUID();
      const data=new FormData(); data.set('token',await accessToken()); data.set('plan',plan); data.set('reference',reference); data.set('requestId',request.current); data.set('file',file);
      await submit({data}); toast.success('Payment proof submitted for review.'); request.current=null;setReference('');setFile(null);if(input.current)input.current.value='';await qc.invalidateQueries({queryKey:['payment-submissions']});
    }catch(e){toast.error(errMsg(e));}finally{setBusy(false);}
  }
  async function view(id:string){try{const result=await proof({data:{token:await accessToken(),id}});window.open(result.url,'_blank','noopener,noreferrer');}catch(e){toast.error(errMsg(e));}}
  const resetRequest=()=>{request.current=null;};
  return <section className="mt-8 border-t pt-6"><h2 className="text-lg font-semibold">Submit payment proof</h2>
    <p className="mt-1 text-sm text-muted-foreground">Payment proofs require admin approval. Uploading does not activate your plan.</p>
    <form onSubmit={save} className="mt-4 grid gap-4 md:grid-cols-2">
      <div><Label htmlFor="proof-plan">Plan</Label><Select value={plan} onValueChange={v=>{setPlan(v as typeof plan);resetRequest();}} disabled={busy}><SelectTrigger id="proof-plan"><SelectValue/></SelectTrigger><SelectContent>{Object.entries(PLANS).map(([k,v])=><SelectItem key={k} value={k}>{v.name}</SelectItem>)}</SelectContent></Select></div>
      <div><Label htmlFor="proof-reference">Transaction reference / UTR</Label><Input id="proof-reference" value={reference} maxLength={100} required disabled={busy} onChange={e=>{setReference(e.target.value);resetRequest();}}/></div>
      <div><Label htmlFor="proof-file">Screenshot · PNG, JPG or WebP · up to 5 MB</Label><Input ref={input} id="proof-file" type="file" accept="image/png,image/jpeg,image/webp" disabled={busy} required onChange={e=>{setFile(e.target.files?.[0]||null);resetRequest();}}/></div>
      <div className="flex items-end"><Button type="submit" disabled={busy||!!history.error}>{busy?'Submitting…':'Submit for review'}</Button></div>
    </form>
    {history.error&&<p role="alert" className="mt-3 text-sm text-destructive">{errMsg(history.error)}</p>}
    {history.isPending&&<p className="mt-4 text-sm text-muted-foreground">Loading submissions…</p>}
    <div className="mt-4 overflow-x-auto"><table className="w-full text-sm"><thead className="bg-muted text-left"><tr>{['Date','Reference','Plan / amount','Status','Review reason','Proof'].map(h=><th className="p-3" key={h}>{h}</th>)}</tr></thead><tbody>{history.data?.map(r=>{const pay=Array.isArray(r.payments)?r.payments[0]:r.payments;return <tr key={r.id} className="border-b"><td className="p-3">{new Date(r.created_at).toLocaleDateString('en-IN')}</td><td className="p-3">{r.reference}</td><td className="p-3">{pay?.plan} · {inr(Number(pay?.amount_paise)/100)}</td><td className="p-3 capitalize">{r.status}</td><td className="p-3">{r.reason||'—'}</td><td className="p-3"><Button size="sm" variant="outline" onClick={()=>view(r.id)}>View</Button></td></tr>;})}</tbody></table>{history.isSuccess&&history.data?.length===0&&<p className="p-4 text-sm text-muted-foreground">No submitted proofs.</p>}</div>
  </section>;
}
