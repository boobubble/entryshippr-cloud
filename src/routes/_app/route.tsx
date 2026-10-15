import { createFileRoute, Outlet, redirect, Link, useNavigate } from "@tanstack/react-router";
import { supabase } from "@/lib/supabase";
import { useProfile, accessState } from "@/lib/hooks";
import { LayoutDashboard, Users, Gauge, Truck, FileSpreadsheet, Receipt, CreditCard, Settings, Shield, LogOut, MapPin } from "lucide-react";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_app")({
  ssr: false,
  beforeLoad: async () => {
    const { data } = await supabase.auth.getUser();
    if (!data.user) throw redirect({ to: "/auth" });
  },
  component: AppLayout,
});

const nav = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
  { to: "/import", label: "Excel import", icon: FileSpreadsheet },
  { to: "/shipments", label: "Shipments", icon: Truck },
  { to: "/clients", label: "Clients", icon: Users },
  { to: "/rate-cards", label: "Rate cards", icon: Gauge },
  { to: "/cities", label: "City & Zone Master", icon: MapPin },
  { to: "/invoices", label: "Invoices", icon: Receipt },
  { to: "/billing", label: "Subscription", icon: CreditCard },
  { to: "/settings", label: "Business settings", icon: Settings },
] as const;

function AppLayout() {
  const { data } = useProfile();
  const navigate = useNavigate();
  const st = accessState(data?.profile);
  return (
    <div className="flex min-h-screen bg-background">
      <aside className="no-print hidden w-60 shrink-0 flex-col bg-sidebar p-4 text-sidebar-foreground md:flex">
        <div className="mb-6 px-2 font-display text-xl font-bold">EntrySetu</div>
        <nav className="flex-1 space-y-1">
          {nav.map((n) => (
            <Link key={n.to} to={n.to} className="flex items-center gap-2 rounded-md px-2 py-2 text-sm hover:bg-sidebar-accent" activeProps={{ className: "bg-sidebar-accent font-semibold" }}>
              <n.icon className="h-4 w-4" />{n.label}
            </Link>
          ))}
          {data?.isAdmin && (
            <Link to="/admin" className="flex items-center gap-2 rounded-md px-2 py-2 text-sm hover:bg-sidebar-accent" activeProps={{ className: "bg-sidebar-accent font-semibold" }}>
              <Shield className="h-4 w-4" />Super admin
            </Link>
          )}
        </nav>
        <div className="mt-4 rounded-md bg-sidebar-accent p-2 text-xs">{st.label}</div>
        <button className="mt-2 flex items-center gap-2 px-2 py-2 text-sm opacity-80 hover:opacity-100" onClick={async () => { await supabase.auth.signOut(); navigate({ to: "/auth" }); }}>
          <LogOut className="h-4 w-4" />Log out
        </button>
      </aside>
      <div className="flex-1 overflow-x-auto">
        <div className="no-print flex gap-1 overflow-x-auto border-b bg-sidebar p-2 md:hidden">
          {nav.map((n) => (
            <Link key={n.to} to={n.to} className="flex items-center gap-1 whitespace-nowrap rounded px-2 py-1 text-xs text-sidebar-foreground" activeProps={{ className: "bg-sidebar-accent font-semibold" }}>
              <n.icon className="h-3.5 w-3.5" />{n.label}
            </Link>
          ))}
        </div>
        {data && !st.active && (
          <div className="no-print flex items-center justify-between gap-4 bg-accent px-6 py-3 text-sm text-accent-foreground">
            Your free trial or plan has ended. Your data is safe, but adding or editing is paused.
            <Button size="sm" asChild><Link to="/billing">Choose a plan</Link></Button>
          </div>
        )}
        {data && !data.profile && (
          <div className="bg-destructive px-6 py-3 text-sm text-destructive-foreground">Database tables not found. Run the EntrySetu SQL script in your Supabase SQL Editor.</div>
        )}
        <main className="mx-auto max-w-6xl p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

