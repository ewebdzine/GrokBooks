-- migration 20261013000118_receipt_attachments
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('receipts','receipts',false,20971520, array['image/jpeg','image/png','image/heic','image/webp','application/pdf']) on conflict (id) do nothing;

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  purchase_id uuid references public.purchases(id) on delete cascade,
  bill_id uuid references public.bills(id) on delete cascade,
  deposit_id uuid references public.deposits(id) on delete cascade,
  storage_path text not null unique,
  file_name text,
  mime_type text,
  size_bytes bigint,
  note text,
  uploaded_by text,
  created_at timestamptz not null default now(),
  constraint attachments_one_parent check (num_nonnulls(purchase_id, bill_id, deposit_id) <= 1)
);
create index on public.attachments(purchase_id);
create index on public.attachments(bill_id);
create index on public.attachments(deposit_id);
alter table public.attachments enable row level security;
