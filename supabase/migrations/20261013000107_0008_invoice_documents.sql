-- migration 20261013000107_0008_invoice_documents
-- GrokBooks 0008: invoice and payment receipt PDF documents.
-- Adds company branding / remittance fields and an invoice_documents table.
-- The private Storage bucket "invoices" holds PDFs and the company logo
-- (PNG or JPEG). companies.logo_path is an object path inside that bucket.
-- There is no bundled logo: a missing logo_path renders as a placeholder.

alter table public.companies
  add column if not exists address              jsonb,
  add column if not exists phone                text,
  add column if not exists email                text,
  add column if not exists website              text,
  add column if not exists logo_path            text,
  add column if not exists remit_to             text,
  add column if not exists payment_instructions text;

create table if not exists public.invoice_documents (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  document_type    text not null default 'invoice_pdf' check (document_type in ('invoice_pdf','payment_receipt_pdf')),
  invoice_id       uuid,
  payment_id       uuid,
  storage_bucket   text not null default 'invoices',
  storage_path     text not null,
  file_size_bytes  integer check (file_size_bytes is null or file_size_bytes > 0),
  sha256           text,
  invoice_total    numeric(14,2),
  amount_paid      numeric(14,2),
  balance_due      numeric(14,2),
  generated_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  amount_unapplied numeric(14,2),
  unique (storage_bucket, storage_path),
  check ((document_type = 'invoice_pdf' and invoice_id is not null and payment_id is null)
      or (document_type = 'payment_receipt_pdf' and payment_id is not null and invoice_id is null)),
  foreign key (company_id, invoice_id) references public.invoices(company_id, id) on delete cascade,
  foreign key (company_id, payment_id) references public.payments(company_id, id) on delete cascade
);
create index if not exists invoice_documents_company_invoice_idx
  on public.invoice_documents (company_id, invoice_id);
create index if not exists invoice_documents_company_payment_idx
  on public.invoice_documents (company_id, payment_id);

create trigger invoice_documents_set_updated_at
  before update on public.invoice_documents
  for each row execute function public.set_updated_at();

alter table public.invoice_documents enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoices', 'invoices', false, 5242880, array['application/pdf','image/png','image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
