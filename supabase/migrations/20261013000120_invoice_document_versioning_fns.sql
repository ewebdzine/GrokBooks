-- migration 20261013000120_invoice_document_versioning_fns
create or replace function public.next_invoice_document_version(p_invoice_id uuid, p_document_type text)
returns int language sql stable security definer set search_path=public as $$
  select coalesce(max(version),0)+1 from invoice_documents where invoice_id=p_invoice_id and document_type=p_document_type;
$$;

create or replace function public.record_invoice_document(
  p_company_id uuid, p_invoice_id uuid, p_payment_id uuid, p_document_type text, p_stamp text,
  p_storage_bucket text, p_storage_path text, p_version int, p_file_size_bytes int, p_sha256 text,
  p_invoice_total numeric, p_amount_paid numeric, p_balance_due numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext(p_invoice_id::text||p_document_type));
  update invoice_documents set is_current=false, updated_at=now()
   where invoice_id=p_invoice_id and document_type=p_document_type and is_current;
  insert into invoice_documents(company_id,invoice_id,payment_id,document_type,stamp,storage_bucket,storage_path,version,is_current,
    file_size_bytes,sha256,invoice_total,amount_paid,balance_due,generated_at)
  values(p_company_id,p_invoice_id,p_payment_id,p_document_type,p_stamp,p_storage_bucket,p_storage_path,p_version,true,
    p_file_size_bytes,p_sha256,p_invoice_total,p_amount_paid,p_balance_due,now())
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_or_create_invoice_link(p_company_id uuid, p_invoice_id uuid)
returns text language plpgsql security definer set search_path=public as $$
declare v_token text;
begin
  perform pg_advisory_xact_lock(hashtext('link'||p_invoice_id::text));
  select token into v_token from invoice_links where invoice_id=p_invoice_id and is_active and revoked_at is null
    and (expires_at is null or expires_at>now()) order by created_at desc limit 1;
  if v_token is null then
    insert into invoice_links(company_id,invoice_id) values(p_company_id,p_invoice_id) returning token into v_token;
  end if;
  return v_token;
end $$;

create or replace function public.consume_invoice_link(p_token text)
returns table(company_id uuid, invoice_id uuid) language sql volatile security definer set search_path=public as $$
  update invoice_links l set view_count=l.view_count+1, last_viewed_at=now()
   where l.token=p_token and l.is_active and l.revoked_at is null and (l.expires_at is null or l.expires_at>now())
  returning l.company_id, l.invoice_id;
$$;

revoke all on function public.next_invoice_document_version(uuid,text), public.record_invoice_document(uuid,uuid,uuid,text,text,text,text,int,int,text,numeric,numeric,numeric), public.get_or_create_invoice_link(uuid,uuid), public.consume_invoice_link(text) from public, anon, authenticated;
grant execute on function public.next_invoice_document_version(uuid,text), public.record_invoice_document(uuid,uuid,uuid,text,text,text,text,int,int,text,numeric,numeric,numeric), public.get_or_create_invoice_link(uuid,uuid), public.consume_invoice_link(text) to service_role;
