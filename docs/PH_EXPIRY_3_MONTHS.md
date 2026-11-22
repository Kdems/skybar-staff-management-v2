# SkyBar PH Policy — Three-calendar-month validity (Migration 011)

## Policy
- A dated PH becomes available on its actual holiday date (Malaysia calendar). It can be used **before** the exclusive expiry date `holiday_date + interval '3 months'`.
- On or after the expiry date (00:00 Malaysia local date), unspent units **BURN**, without notifications, warnings or reminders.
- Example: holiday **1 January 2027** -> valid through **31 March 2027** -> burns from **1 April 2027**. Holiday **31 January 2027** -> valid through **29 April 2027** -> burns from **30 April 2027** (PostgreSQL calendar-month handling).
- Both original staff PH submissions and Admin AL/EL/OFF -> PH conversion require **submission date and final leave date** to be earlier than expiry. No expired PH can be reallocated after a cancellation or refund.
- Credits already reserved for Pending/Approved leave remain in history, and only their **unspent** portion burns. Nothing is physically deleted; availability and `BURN` are computed automatically based on today's Malaysia date, without a cron job.
- **Important limitation:** older manual/historical opening PH credits may lack an actual `holiday_date`. There is no reliable start date for those records, so migration 011 leaves them active rather than inventing an expiry. Admin/HR should reconcile these separately if the same three-month rule must apply to them. All dated PH credits (including the 2027 annual schedule) are subject to the rule.
- No push alerts, automatic emails, countdown reminders, or toast messages are introduced.

## Deployment order
1. Retain a current protected database backup; never add real staff data or service credentials to GitHub.
2. Run `supabase/migrations/20261122_011_ph_three_month_expiry.sql` once in the **existing production project** SQL Editor. Do not rerun migrations 001–010. It adds one generated `expires_on` column, updates two server-side validation functions and retains the **1 January 2027 production lock**.
3. Deploy latest `supabase/functions/staff-api/index.ts` to the **existing** Supabase Edge Function `staff-api`; keep **Verify JWT OFF** for the app's custom Staff ID/PIN sessions. This is required for staff dashboard balance and Admin PH Excel reports.
4. Wait for current GitHub `main` Cloudflare deployment, then hard-refresh `https://skybar-staff-management-v2.texas-boiler.workers.dev/`. No new Worker is required.
5. Run `supabase/checks/ph_three_month_expiry_readonly.sql`. The second result must show **protected_submission_paths=2**, **new_year_burn_date=2027-04-01**, **jan_31_burn_date=2027-04-30**. Review any **undated_historical_credits** before deciding their treatment.
6. View Admin -> AL & PH Management -> Public Holiday Credit Ledger. Date-based credits show LOCKED/RELEASED/BURN (or USED if fully consumed). Reports include expiry, reserved and burned units. Check member PH Available balance against ledger.

## Rollback / operations
- Treat 011 as a live business-policy change; do not blindly replay old 004/006 functions, because doing so would remove the expiry validation.
- Date computation is dynamic: no new cron, scheduled maintenance, or alerts; do not update `active` or delete historical PH usage merely to mark BURN.
- If SQL Editor reports an error, stop before updating the Edge Function; the migration is atomic and should roll back. Report the exact error.
