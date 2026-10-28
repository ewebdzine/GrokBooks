-- migration 20261013000119_invoice_pdf_storage_and_links
-- Keep image types so a company logo (PNG/JPEG) can live in this bucket next to PDFs.
-- On conflict, leave the bucket created in 0008 unchanged.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoices','invoices',false,10485760, array['application/pdf','image/png','image/jpeg'])
on conflict (id) do nothing;

alter table public.invoice_documents add column if not exists version integer not null default 1, add column if not exists is_current boolean not null default true;
create unique index if not exists invoice_documents_path_uq on public.invoice_documents(storage_bucket, storage_path);
create unique index if not exists invoice_documents_one_current on public.invoice_documents(invoice_id, document_type) where is_current;

create table public.invoice_links (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  token text not null unique default encode(extensions.gen_random_bytes(24),'hex'),
  is_active boolean not null default true,
  expires_at timestamptz,
  view_count integer not null default 0,
  last_viewed_at timestamptz,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index on public.invoice_links(invoice_id);
alter table public.invoice_links enable row level security;
