# GitHub reference projects for a QuickBooks Online schema (checked Sep 30, 2026)

## Best references
1. **fivetran/dbt_quickbooks_source**: https://github.com/fivetran/dbt_quickbooks_source
   One staging model per QuickBooks table, with lines and links split into child tables: account, customer, vendor, item, invoice + invoice_line + invoice_linked_txn, bill + bill_line + bill_linked_txn, payment + payment_line, bill_payment + bill_payment_line, purchase + purchase_line, deposit + deposit_line, journal_entry + journal_entry_line, credit_memo, vendor_credit, transfer, sales_receipt, refund_receipt, estimate, purchase_order. Column-by-column docs: https://fivetran.github.io/dbt_quickbooks_source/
2. **fivetran/dbt_quickbooks** (41 stars, active): https://github.com/fivetran/dbt_quickbooks
   Builds on top of those tables. It turns every transaction type into double-entry general ledger rows, then produces a general ledger, balance sheet, profit and loss, cash flow, and A/R and A/P aging. This is the model for building reports from the raw tables.
3. **singer-io/tap-quickbooks**: https://github.com/singer-io/tap-quickbooks
   One JSON Schema file per QuickBooks object (field names and types): accounts, bills, bill_payments, customers, deposits, invoices, items, journal_entries, payments, purchases, vendors, transfers, credit_memos, vendor_credits, classes, terms, payment_methods, deleted_objects, and more. Good for exact field types.
4. **hotgluexyz/tap-quickbooks**: https://github.com/hotgluexyz/tap-quickbooks
   An actively maintained Singer tap with similar per-object schemas.
5. **dbt-labs/quickbooks**: https://github.com/dbt-labs/quickbooks
   The original dbt QuickBooks Online models (last updated 2020). An older version of #1 and #2.

## Supabase-specific (small, unproven, not reviewed)
- **pavlov-backend/supabase-quickbooks-sync-engine**: https://github.com/pavlov-backend/supabase-quickbooks-sync-engine
  QuickBooks OAuth plus automated sync into Supabase using Edge Functions (2026).
- **mario-p3na/supabase-quickbooks**: https://github.com/mario-p3na/supabase-quickbooks
  A simple server that imports QuickBooks invoices into Supabase and keeps them updated with webhooks (2024).

## Also seen
- Airbyte QuickBooks connector (airbytehq/airbyte, under airbyte-integrations/connectors/source-quickbooks): a full sync connector with per-stream schemas.
- Dreadpool/sle-quickbooks-gl-docs: QuickBooks general ledger data in BigQuery, with schema docs and audit queries.
- Grimrieber/QBToSQL: QuickBooks *Desktop* to SQL Server. Not QuickBooks Online.
