import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useProfile } from "@/lib/hooks";
import { loadInvoice, linesForDocument } from "@/lib/invoices";
import { appHead } from "@/components/PageHead";
import { Button } from "@/components/ui/button";
import { InvoiceDocument, type InvoiceDocumentProps } from "@/components/InvoiceDocument";
import { ArrowLeft, Pencil, Printer } from "lucide-react";

export const Route = createFileRoute("/_app/invoices/$id")({
  head: appHead("Invoice", "Printable courier invoice."),
  component: InvoiceView,
});

function InvoiceView() {
  const { id } = Route.useParams();
  const { data: me } = useProfile();
  const { data, error } = useQuery({ queryKey: ["invoice", id], queryFn: () => loadInvoice(id) });
  if (error) return <p className="text-destructive">{error.message}</p>;
  if (!data) return <p className="text-muted-foreground">Loading…</p>;
  const { inv, lines, charges, ships } = data;
  const rows = (lines.length ? linesForDocument(lines) : ships) as InvoiceDocumentProps["shipments"];
  return (
    <div className="invoice-page">
      <div className="no-print mb-4 flex flex-wrap gap-2">
        <Button variant="outline" asChild><Link to="/invoices"><ArrowLeft />Back</Link></Button>
        {inv.status === "draft" && <Button asChild><Link to="/invoices/edit/$id" params={{ id }}><Pencil />Edit draft</Link></Button>}
        {inv.status !== "draft" && <Button onClick={() => window.print()}><Printer />Print / Save PDF</Button>}
      </div>
      <div className="invoice-scroll overflow-x-auto">
        <InvoiceDocument seller={me?.profile} invoice={inv} shipments={rows} charges={charges} />
      </div>
    </div>
  );
}
