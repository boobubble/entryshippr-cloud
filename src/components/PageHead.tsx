export function PageHead({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className="no-print mb-6 flex flex-wrap items-center justify-between gap-3">
      <h1 className="text-2xl font-bold">{title}</h1>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
  );
}

export const appHead = (title: string, description: string) => () => ({
  meta: [
    { title: `${title} — EntrySetu` },
    { name: "description", content: description },
    { property: "og:title", content: `${title} — EntrySetu` },
    { property: "og:description", content: description },
    { property: "og:type", content: "website" },
    { name: "twitter:card", content: "summary" },
  ],
});
