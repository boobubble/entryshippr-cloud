import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { useProfile } from "@/lib/hooks";
import { appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { InvoiceDocument } from "@/components/InvoiceDocument";
import { ArrowLeft, Printer } from "lucide-react";

export const Route = createFileRoute("/_app/invoices/$id")({
  head: appHead("Invoice", "Printable courier invoice."),
  component: InvoiceView,
});

function InvoiceView() {
  const { id } = Route.useParams();
  const { data: me } = useProfile();
  const { data } = useQuery({
    queryKey: ["invoice", id],
    queryFn: async () => {
      const { data: inv, error } = await supabase.from("invoices").select("*, clients(*)").eq("id", id).single();
      if (error) throw error;
      const { data: ships } = await supabase.from("shipments").select("*").eq("invoice_id", id).order("ship_date");
      return { inv, ships: ships || [] };
    },
  });
  if (!data) return <p className="text-muted-foreground">Loading…</p>;
  const { inv, ships } = data;
  return (
    <div className="invoice-page">
      <div className="no-print mb-4 flex flex-wrap gap-2"><Button variant="outline" asChild><Link to="/invoices"><ArrowLeft />Back</Link></Button><Button onClick={() => window.print()}><Printer />Print / Save PDF</Button></div>
      <div className="invoice-scroll overflow-x-auto">
        <InvoiceDocument seller={me?.profile} invoice={inv} shipments={ships} />
      </div>
    </div>
  );
}
