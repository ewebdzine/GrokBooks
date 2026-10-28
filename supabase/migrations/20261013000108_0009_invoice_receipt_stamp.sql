-- migration 20261013000108_0009_invoice_receipt_stamp
alter table public.invoice_documents drop constraint if exists invoice_documents_check;
alter table public.invoice_documents drop constraint if exists invoice_documents_document_type_check;
alter table public.invoice_documents drop column if exists amount_unapplied;

alter table public.invoice_documents
  alter column invoice_id set not null,
  add column if not exists stamp text check (stamp in ('paid','partial')),
  add constraint invoice_documents_document_type_check
    check (document_type in ('invoice_pdf','invoice_receipt_pdf')),
  add constraint invoice_documents_stamp_matches_type
    check ((document_type = 'invoice_pdf' and stamp is null)
        or (document_type = 'invoice_receipt_pdf' and stamp is not null));
