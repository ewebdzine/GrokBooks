# QuickBooks field dictionary

Field names QuickBooks Online returns for the objects GrokBooks stores. "Refs" are
links to another record: `.value` is the linked id and `.name` is its display name.
Housekeeping fields (`domain`, `sparse`, `CustomExtensions`) are omitted. `Line[]`
means one row per line item, which becomes a child table.

Values below are illustrative shapes, not data from any real company. Every record
also has `Id`, `SyncToken`, `CurrencyRef`, `MetaData.CreateTime`, and
`MetaData.LastUpdatedTime`.

## Account
`Id`, `Name`, `FullyQualifiedName`, `AcctNum`, `AccountType` (for example "Accounts Receivable"),
`AccountSubType`, `Classification` ("Asset", "Liability", "Equity", "Revenue", "Expense"),
`Active`, `SubAccount`, `ParentRef.value`, `Description`, `CurrentBalance`,
`CurrentBalanceWithSubAccounts`.

## Item
`Id`, `Name`, `FullyQualifiedName`, `Type` ("Service", "Inventory", "NonInventory"),
`UnitPrice`, `PurchaseCost`, `Taxable`, `TrackQtyOnHand`, `Active`, `Description`,
`IncomeAccountRef.value` / `.name`.

## Vendor
`Id`, `DisplayName`, `PrintOnCheckName`, `CompanyName`, `GivenName`, `MiddleName`,
`FamilyName`, `Active`, `Balance`, `BillRate`, `CostRate`, `Vendor1099`, `TaxIdentifier`
(store masked only), `PrimaryEmailAddr.Address`, `BillAddr` (`Line1`, `City`,
`CountrySubDivisionCode`, `PostalCode`).

## Customer
`Id`, `DisplayName`, `FullyQualifiedName`, `PrintOnCheckName`, `CompanyName`, `GivenName`,
`MiddleName`, `FamilyName`, `Active`, `Balance`, `BalanceWithJobs`, `BillWithParent`,
`IsProject`, `Job`, `Taxable`, `PreferredDeliveryMethod`, `PrimaryEmailAddr.Address`,
`Mobile.FreeFormNumber`, `BillAddr`, `ShipAddr`.

## Invoice
Header: `Id`, `DocNumber`, `TxnDate`, `DueDate`, `CustomerRef.value` / `.name`, `TotalAmt`,
`Balance` (above 0 means open), `SalesTermRef`, `RecurDataRef` (recurring template),
`EmailStatus`, `EInvoiceStatus`, `PrintStatus`, `PrivateNote`, `CustomerMemo.value`,
`PaymentRefNum`, `BillEmail.Address`, `BillAddr`, `ShipAddr`, `ShipFromAddr`,
`DeliveryInfo`, `CustomField`, online-payment flags, `ApplyTaxAfterDiscount`, `FreeFormAddress`.

Links: `LinkedTxn[].TxnId` / `TxnType` "Payment" points at payments applied to the invoice.

Line[]: `Id`, `LineNum`, `Amount`, `Description`, `DetailType` "SalesItemLineDetail"
(skip "SubTotalLineDetail"), `SalesItemLineDetail.ItemRef`, `.ItemAccountRef`, `.Qty`,
`.UnitPrice`, `.TaxCodeRef`.

## Payment (customer payments)
Header: `Id`, `TxnDate`, `CustomerRef`, `TotalAmt`, `UnappliedAmt`, `DepositToAccountRef`
(checking, or Undeposited Funds), `PaymentMethodRef`, `PaymentRefNum`, `PrivateNote`,
`ProcessPayment`, `TxnSource`.

Card and ACH detail, when present: `CreditCardPayment.CreditChargeInfo`, `CreditChargeResponse`.

Links: `LinkedTxn[]` with `TxnType` "Deposit" is the deposit that swept the payment out of
Undeposited Funds.

Line[]: `Amount`, `LinkedTxn[].TxnId` / `TxnType` "Invoice" (the payment-to-invoice link).
One payment can cover more than one invoice.

## Bill
Header: `Id`, `DocNumber`, `TxnDate`, `DueDate`, `VendorRef`, `APAccountRef`, `TotalAmt`,
`Balance`, `RecurDataRef`, `VendorAddr`.

Links: `LinkedTxn[]` / "BillPaymentCheck".

Line[]: `Id`, `LineNum`, `Amount`, `Description`, `DetailType` "AccountBasedExpenseLineDetail",
`AccountBasedExpenseLineDetail.AccountRef`, `.BillableStatus`, `.TaxCodeRef`.

## BillPayment
Header: `Id`, `DocNumber`, `TxnDate`, `VendorRef`, `TotalAmt`, `PayType` ("Check"),
`CheckPayment.BankAccountRef`, `CheckPayment.PrintStatus`, `PrivateNote`.

Line[]: `Amount`, `LinkedTxn[].TxnId` / `TxnType` "Bill".

## Purchase (direct expenses and checks)
Header: `Id`, `DocNumber`, `TxnDate`, `PaymentType` ("Cash", "Check", "CreditCard"),
`AccountRef` (the account paid from), `EntityRef` (vendor or customer), `TotalAmt`,
`PaymentMethodRef`, `RecurDataRef`, `PrivateNote`, `PrintStatus`, `RemitToAddr`.

Line[]: `Id`, `Amount`, `Description`, `AccountBasedExpenseLineDetail.AccountRef`,
`.CustomerRef`, `.BillableStatus`, `.TaxCodeRef`.

## Deposit
Header: `Id`, `TxnDate`, `DepositToAccountRef`, `TotalAmt`, `PrivateNote`.

Line[]: `Id`, `LineNum`, `Amount`, `Description`, `DetailType` "DepositLineDetail",
`DepositLineDetail.AccountRef`, `.Entity`, `.PaymentMethodRef`.

Links: `Line[].LinkedTxn[]` / "Payment" when the deposit sweeps customer payments out of
Undeposited Funds.

## JournalEntry
Header: `Id`, `DocNumber`, `TxnDate`, `Adjustment`, `TotalAmt`, `PrivateNote`.

Line[]: `Id`, `Amount`, `Description`, `JournalEntryLineDetail.PostingType` ("Debit" or "Credit"),
`.AccountRef`, `.Entity`.

## Not modeled as their own tables
Sales receipts, credit memos, vendor credits, classes, employees, estimates, and the
recurring templates themselves (only `RecurDataRef` ids are stored on the transactions
they generate). Transfers are a GrokBooks table. Fixed assets are a GrokBooks register,
not a QuickBooks object.
