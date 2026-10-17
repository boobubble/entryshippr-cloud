import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useServerFn } from '@tanstack/react-start';
import { toast } from 'sonner';
import { accessToken,supabase,inr } from '@/lib/supabase';
import { errMsg } from '@/lib/hooks';
import { paymentProofUrl,reviewPaymentProof } from '@/lib/payment-proofs.functions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Select,SelectContent,SelectItem,SelectTrigger,SelectValue } from '@/components/ui/select';
import { Dialog,DialogContent,DialogHeader,DialogTitle,DialogFooter } from '@/components/ui/dialog';
export function PaymentReview(){
 const [status,setStatus]=useState('pending');const [page,setPage]=useState(0);const [search,setSearch]=useState(''); const [from,setFrom]=useState(''); const [to,setTo]=useState('');
 const [selection,setSelection]=useState<{id:string;decision:'approved'|'rejected'}|null>(null);const [reason,setReason]=useState('');const [busy,setBusy]=useState(false);
 const qc=useQueryClient();const review=useServerFn(reviewPaymentProof); const proof=useServerFn(paymentProofUrl);
 const rows=useQuery({queryKey:['payment-review',status,page,search,from,to],retry:false,queryFn:async()=>{
   const role=await supabase.rpc('is_admin'); if(role.error||role.data!==true)throw new Error('Admins only.');
   let q=supabase.from('payment_submissions').select('id,owner_id,reference,status,reason,created_at,payments(plan,amount_paise)',{count:'exact'}).not('submitted_at','is',null).order('created_at',{ascending:false}).order('id');
   if(status!=='all')q=q.eq('status',status);if(search.trim())q=q.ilike('reference',`%${search.trim().replace(/[%_]/g,'')}%`);
   if(from)q=q.gte('created_at',`${from}T00:00:00Z`);if(to)q=q.lt('created_at',new Date(new Date(`${to}T00:00:00Z`).getTime()+86400000).toISOString());
   const r=await q.range(page*20,page*20+19);if(r.error)throw new Error('Payment reviews are awaiting the reviewed DEV setup.');return {rows:r.data||[],count:r.count||0};
 }});
 async function view(id:string){try{const r=await proof({data:{token:await accessToken(),id}});window.open(r.url,'_blank','noopener,noreferrer');}catch(e){toast.error(errMsg(e));}}
 async function decide(){if(!selection||busy)return;setBusy(true);try{await review({data:{token:await accessToken(),...selection,reason}});toast.success(`Payment ${selection.decision}.`);setSelection(null);setReason('');await Promise.all([qc.invalidateQueries({queryKey:['payment-review']}),qc.invalidateQueries({queryKey:['admin']}),qc.invalidateQueries({queryKey:['subscription-audit']})]);}catch(e){toast.error(errMsg(e));}finally{setBusy(false);}}
 return <section className="mt-8 border-t pt-6"><h2 className="text-lg font-semibold">Payment verification</h2><div className="my-4 grid gap-3 sm:grid-cols-4">
 <div><Label>Status</Label><Select value={status} onValueChange={v=>{setStatus(v);setPage(0);}}><SelectTrigger><SelectValue/></SelectTrigger><SelectContent>{['pending','approved','rejected','all'].map(v=><SelectItem key={v} value={v}>{v}</SelectItem>)}</SelectContent></Select></div>
 <div><Label htmlFor="review-search">Reference / UTR</Label><Input id="review-search" value={search} maxLength={100} onChange={e=>{setSearch(e.target.value);setPage(0);}}/></div>
 <div><Label htmlFor="review-from">From (UTC)</Label><Input id="review-from" type="date" value={from} onChange={e=>{setFrom(e.target.value);setPage(0);}}/></div><div><Label htmlFor="review-to">To (UTC)</Label><Input id="review-to" type="date" value={to} onChange={e=>{setTo(e.target.value);setPage(0);}}/></div></div>
 {rows.error&&<p role="alert" className="text-sm text-destructive">{errMsg(rows.error)}</p>}{rows.isPending&&<p>Loading reviews…</p>}
 <div className="overflow-x-auto"><table className="w-full text-sm"><thead className="bg-muted text-left"><tr>{['Seller ID','Reference','Plan / amount','Status / reason','Actions'].map(h=><th className="p-3" key={h}>{h}</th>)}</tr></thead><tbody>{rows.data?.rows.map(r=>{const p=Array.isArray(r.payments)?r.payments[0]:r.payments;return <tr className="border-b" key={r.id}><td className="p-3 font-mono text-xs">{r.owner_id}</td><td className="p-3">{r.reference}</td><td className="p-3">{p?.plan} · {inr(Number(p?.amount_paise)/100)}</td><td className="p-3 capitalize">{r.status}<p className="text-muted-foreground">{r.reason}</p></td><td className="space-x-2 whitespace-nowrap p-3"><Button size="sm" variant="outline" onClick={()=>view(r.id)}>View proof</Button>{r.status==='pending'&&<><Button size="sm" onClick={()=>{setSelection({id:r.id,decision:'approved'});setReason('');}}>Approve</Button><Button size="sm" variant="destructive" onClick={()=>{setSelection({id:r.id,decision:'rejected'});setReason('');}}>Reject</Button></>}</td></tr>;})}</tbody></table></div>
 {rows.data?.count===0&&<p className="p-4 text-muted-foreground">No matching submissions.</p>}<div className="mt-3 flex items-center justify-end gap-3"><Button variant="outline" size="sm" disabled={page===0} onClick={()=>setPage(p=>p-1)}>Previous</Button><span className="text-sm">Page {page+1}</span><Button variant="outline" size="sm" disabled={!rows.data||((page+1)*20>=rows.data.count)} onClick={()=>setPage(p=>p+1)}>Next</Button></div>
 <Dialog open={!!selection} onOpenChange={open=>{if(!open&&!busy)setSelection(null);}}><DialogContent><DialogHeader><DialogTitle>{selection?.decision==='approved'?'Approve payment':'Reject payment'}</DialogTitle></DialogHeader><Label htmlFor="review-reason">Review reason</Label><Textarea id="review-reason" value={reason} maxLength={1000} disabled={busy} onChange={e=>setReason(e.target.value)}/><DialogFooter><Button disabled={busy||reason.trim().length<3} onClick={decide}>{busy?'Saving…':'Confirm review'}</Button></DialogFooter></DialogContent></Dialog>
 </section>;
}
