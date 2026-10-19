import { createFileRoute, Link } from "@tanstack/react-router";
import { listPublishedPosts } from "@/lib/blog.functions";
import { LatestPosts } from "@/components/blog/LatestPosts";
import { queryOptions, useSuspenseQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { PLANS, JOINING_FEE, inr } from "@/lib/supabase";
import { FileSpreadsheet, Receipt, Users, Truck, ShieldCheck, Gauge } from "lucide-react";

const latestQuery = queryOptions({ queryKey: ["latest-posts"], queryFn: () => listPublishedPosts({ data: { page: 0, limit: 4 } }) });
export const Route = createFileRoute("/")({
  loader: ({ context }) => context.queryClient.ensureQueryData(latestQuery),
  head: () => ({
    links: [{ rel: "canonical", href: "https://entryshippr-cloud.lovable.app/" }],
    meta: [
      { title: "EntrySetu — Your Business Entry & Billing Bridge" },
      { name: "description", content: "Courier entry, Excel import, rate cards and GST/Non-GST invoicing in one place. Start a 5-day free trial." },
      { property: "og:title", content: "EntrySetu — Your Business Entry & Billing Bridge" },
      { property: "og:description", content: "Courier entry and GST billing SaaS for Indian courier businesses." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Landing,
});

const features = [
  { icon: FileSpreadsheet, t: "Excel processing", d: "Upload your daily booking sheet; AWBs, weights and amounts are entered automatically." },
  { icon: Truck, t: "Shipments", d: "Every consignment searchable by AWB, client and date." },
  { icon: Users, t: "Client management", d: "GST and non-GST clients with addresses and state." },
  { icon: Gauge, t: "Rate cards", d: "Weight slabs per service, per client or default." },
  { icon: Receipt, t: "GST invoicing", d: "CGST/SGST or IGST worked out automatically. Print-ready." },
  { icon: ShieldCheck, t: "Private by design", d: "Each business sees only its own data." },
];

function Landing() {
  const { data: latest } = useSuspenseQuery(latestQuery);
  return (
    <div className="min-h-screen bg-background">
      <header className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
        <div className="font-display text-xl font-bold text-primary">Entry<span className="text-accent-foreground">Setu</span></div>
        <div className="flex gap-2">
          <Button variant="ghost" asChild><Link to="/auth">Log in</Link></Button>
          <Button asChild><Link to="/auth" search={{ mode: "signup" }}>Start free trial</Link></Button>
        </div>
      </header>
      <section className="mx-auto max-w-6xl px-6 pb-16 pt-12">
        <p className="mb-4 inline-block rounded-full bg-accent px-3 py-1 text-xs font-semibold text-accent-foreground">For courier franchisees & booking centres</p>
        <h1 className="max-w-3xl text-4xl font-bold leading-tight text-foreground md:text-6xl">Your business entry &amp; billing bridge.</h1>
        <p className="mt-5 max-w-2xl text-lg text-muted-foreground">Turn daily booking sheets into shipments and month-end GST invoices in minutes. No more manual typing.</p>
        <div className="mt-8 flex gap-3">
          <Button size="lg" asChild><Link to="/auth" search={{ mode: "signup" }}>Try free for 5 days</Link></Button>
          <Button size="lg" variant="outline" asChild><a href="#pricing">See pricing</a></Button>
        </div>
      </section>
      <section className="mx-auto grid max-w-6xl gap-4 px-6 pb-20 md:grid-cols-3">
        {features.map((f) => (
          <div key={f.t} className="rounded-xl border bg-card p-6">
            <f.icon className="h-6 w-6 text-primary" />
            <h3 className="mt-3 font-semibold">{f.t}</h3>
            <p className="mt-1 text-sm text-muted-foreground">{f.d}</p>
          </div>
        ))}
      </section>
      <section id="pricing" className="bg-sidebar py-20 text-sidebar-foreground">
        <div className="mx-auto max-w-4xl px-6">
          <h2 className="text-3xl font-bold">Simple yearly pricing</h2>
          <p className="mt-2 opacity-80">{JOINING_FEE > 0 ? `One-time joining fee of ${inr(JOINING_FEE)} on your first paid purchase.` : "No joining fee for either plan."} Prices in INR.</p>
          <div className="mt-8 grid gap-4 md:grid-cols-2">
            {(Object.keys(PLANS) as (keyof typeof PLANS)[]).map((k) => (
              <div key={k} className="rounded-xl bg-sidebar-accent p-6">
                <h3 className="text-lg font-semibold">{PLANS[k].name}</h3>
                <div className="mt-2 text-3xl font-bold">{inr(PLANS[k].price)}<span className="text-sm font-normal opacity-70"> /year</span></div>
                <p className="mt-2 opacity-80">{PLANS[k].limit}</p>
                <Button className="mt-5 w-full" variant="secondary" asChild><Link to="/auth" search={{ mode: "signup" }}>Start 5-day trial</Link></Button>
              </div>
            ))}
          </div>
        </div>
      </section>
      <LatestPosts posts={latest.posts} />
      <footer className="py-8 text-center text-sm text-muted-foreground">© {new Date().getFullYear()} EntrySetu</footer>
    </div>
  );
}
