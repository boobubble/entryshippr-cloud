import { createFileRoute } from "@tanstack/react-router";

import registry from "@/data/city-registry.json";

// Daily global city sync from the reviewed registry in src/data/city-registry.json.
// Only adds cities / aliases (sync_cities); never touches seller zone assignments.
// Call with header x-sync-secret = CITY_SYNC_SECRET (e.g. from Supabase pg_cron + pg_net).
export const Route = createFileRoute("/api/public/city-sync")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { rest, safeEqual } = await import("@/lib/billing.server");
        const secret = process.env["CITY_SYNC_SECRET"];
        if (!secret) return new Response("City sync not configured", { status: 503 });
        if (!safeEqual(request.headers.get("x-sync-secret") || "", secret)) return new Response("Unauthorized", { status: 401 });
        try {
          const result = await rest("rpc/sync_cities", { method: "POST", body: JSON.stringify({ p: registry }) });
          return Response.json({ ok: true, result });
        } catch (e) {
          console.error("City sync failed", e);
          return new Response("Sync failed", { status: 500 });
        }
      },
    },
  },
});
