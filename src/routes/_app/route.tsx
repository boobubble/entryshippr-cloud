import { createFileRoute, Outlet, redirect, Link, useNavigate, useRouterState } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { useProfile, accessState } from "@/lib/hooks";
import { LayoutDashboard, Users, Gauge, Truck, FileSpreadsheet, Receipt, CreditCard, Settings, Shield, LogOut, MapPin, Menu, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { setSidebarCollapsed, useSidebarCollapsed } from "@/lib/sidebar";

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
  { to: "/cities", label: "City & Zone Master", icon: MapPin },
  { to: "/rate-cards", label: "Rate Cards", icon: Gauge },
  { to: "/invoices", label: "Invoices", icon: Receipt },
  { to: "/billing", label: "Subscription", icon: CreditCard },
  { to: "/settings", label: "Business settings", icon: Settings },
] as const;

function SideContent({ isAdmin, label, onLogout }: { isAdmin?: boolean; label: string; onLogout: () => void }) {
  const link = "flex items-center gap-2 rounded-md px-2 py-2 text-sm hover:bg-sidebar-accent";
  return (
    <>
      <nav className="flex-1 space-y-1">
        {nav.map((n) => (
          <Link key={n.to} to={n.to} className={link} activeProps={{ className: "bg-sidebar-accent font-semibold" }}>
            <n.icon className="h-4 w-4" />{n.label}
          </Link>
        ))}
        {isAdmin && (
          <Link to="/admin" className={link} activeProps={{ className: "bg-sidebar-accent font-semibold" }}>
            <Shield className="h-4 w-4" />Super admin
          </Link>
        )}
      </nav>
      <div className="mt-4 rounded-md bg-sidebar-accent p-2 text-xs">{label}</div>
      <button className="mt-2 flex items-center gap-2 px-2 py-2 text-sm opacity-80 hover:opacity-100" onClick={onLogout}>
        <LogOut className="h-4 w-4" />Log out
      </button>
    </>
  );
}

function AppLayout() {
  const { data } = useProfile();
  const navigate = useNavigate();
  const st = accessState(data?.profile);
  const collapsed = useSidebarCollapsed();
  const [drawer, setDrawer] = useState(false);
  const path = useRouterState({ select: (s) => s.location.pathname });
  useEffect(() => setDrawer(false), [path]);
  const logout = async () => { await supabase.auth.signOut(); navigate({ to: "/auth" }); };
  const toggle = () => {
    if (window.matchMedia("(min-width: 768px)").matches) setSidebarCollapsed(!collapsed);
    else setDrawer((v) => !v);
  };
  return (
    <div className="flex min-h-screen bg-background">
      <aside className={`no-print hidden w-60 shrink-0 flex-col bg-sidebar p-4 text-sidebar-foreground ${collapsed ? "" : "md:flex"}`}>
        <SideContent isAdmin={data?.isAdmin} label={st.label} onLogout={logout} />
      </aside>
      {drawer && (
        <div className="no-print fixed inset-0 z-50 md:hidden">
          <div className="absolute inset-0 bg-foreground/40" onClick={() => setDrawer(false)} />
          <aside className="relative flex h-full w-64 flex-col bg-sidebar p-4 text-sidebar-foreground shadow-xl">
            <div className="mb-4 flex items-center justify-between px-2">
              <span className="font-display text-xl font-bold">EntrySetu</span>
              <button aria-label="Close menu" onClick={() => setDrawer(false)}><X className="h-5 w-5" /></button>
            </div>
            <SideContent isAdmin={data?.isAdmin} label={st.label} onLogout={logout} />
          </aside>
        </div>
      )}
      <div className="min-w-0 flex-1">
        <header className="no-print flex h-12 items-center gap-3 border-b bg-sidebar px-3 text-sidebar-foreground">
          <Button variant="ghost" size="icon" aria-label={collapsed ? "Show menu" : "Hide menu"} aria-expanded={!collapsed} onClick={toggle} className="hover:bg-sidebar-accent">
            <Menu className="h-5 w-5" />
          </Button>
          <span className="font-display text-lg font-bold">EntrySetu</span>
        </header>
        {data && !st.active && (
          <div className="no-print flex items-center justify-between gap-4 bg-accent px-6 py-3 text-sm text-accent-foreground">
            Your free trial or plan has ended. Your data is safe, but adding or editing is paused.
            <Button size="sm" asChild><Link to="/billing">Choose a plan</Link></Button>
          </div>
        )}
        {data && !data.profile && (
          <div className="bg-destructive px-6 py-3 text-sm text-destructive-foreground">Database tables not found. Run the EntrySetu SQL script in your Supabase SQL Editor.</div>
        )}
        <main className={`mx-auto p-4 md:p-6 ${collapsed ? "max-w-[1600px]" : "max-w-6xl"}`}>
          <Outlet />
        </main>
      </div>
    </div>
  );
}
