import { useSyncExternalStore } from "react";

// Tiny in-memory store for the desktop sidebar; not persisted, so other pages keep their normal layout.
let collapsed = false;
const subs = new Set<() => void>();
export const setSidebarCollapsed = (v: boolean) => { collapsed = v; subs.forEach((f) => f()); };
export const getSidebarCollapsed = () => collapsed;
export const useSidebarCollapsed = () =>
  useSyncExternalStore((f) => { subs.add(f); return () => subs.delete(f); }, () => collapsed, () => false);
