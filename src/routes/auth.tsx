import { createFileRoute, useNavigate, Link } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/auth")({
  validateSearch: (s: Record<string, unknown>) => ({ mode: s.mode === "signup" ? "signup" : s.mode === "forgot" ? "forgot" : undefined }) as { mode?: "signup" | "forgot" },
  head: () => ({
    meta: [
      { title: "Log in or sign up — EntrySetu" },
      { name: "description", content: "Sign in to EntrySetu or start your 5-day free trial." },
      { property: "og:title", content: "Log in — EntrySetu" },
      { property: "og:description", content: "Access your EntrySetu courier billing account." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const { mode } = Route.useSearch();
  const nav = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [business, setBusiness] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState("");

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      if (mode === "signup") {
        const { data, error } = await supabase.auth.signUp({ email, password, options: { emailRedirectTo: window.location.origin + "/dashboard", data: { business_name: business } } });
        if (error) throw error;
        if (data.session) nav({ to: "/dashboard" });
        else setSent("Check your email to confirm your account, then log in.");
      } else if (mode === "forgot") {
        const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: window.location.origin + "/reset-password" });
        if (error) throw error;
        setSent("Password reset link sent to your email.");
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        nav({ to: "/dashboard" });
      }
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm rounded-xl border bg-card p-8">
        <Link to="/" className="font-display text-xl font-bold text-primary">EntrySetu</Link>
        <h1 className="mt-4 text-2xl font-bold">{mode === "signup" ? "Start your free trial" : mode === "forgot" ? "Reset password" : "Welcome back"}</h1>
        {sent ? (
          <p className="mt-4 text-sm text-muted-foreground">{sent}</p>
        ) : (
          <form onSubmit={submit} className="mt-6 space-y-4">
            {mode === "signup" && (
              <div><Label>Business name</Label><Input required value={business} onChange={(e) => setBusiness(e.target.value)} /></div>
            )}
            <div><Label>Email</Label><Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></div>
            {mode !== "forgot" && (
              <div><Label>Password</Label><Input type="password" required minLength={6} value={password} onChange={(e) => setPassword(e.target.value)} /></div>
            )}
            <Button className="w-full" disabled={busy}>{busy ? "Please wait…" : mode === "signup" ? "Create account" : mode === "forgot" ? "Send reset link" : "Log in"}</Button>
          </form>
        )}
        <div className="mt-6 space-y-1 text-sm">
          {mode !== "signup" && <Link to="/auth" search={{ mode: "signup" }} className="block text-primary">New here? Start a 5-day free trial</Link>}
          {mode !== undefined && <Link to="/auth" search={{}} className="block text-primary">Already have an account? Log in</Link>}
          {mode === undefined && <Link to="/auth" search={{ mode: "forgot" }} className="block text-muted-foreground">Forgot password?</Link>}
        </div>
      </div>
    </div>
  );
}
