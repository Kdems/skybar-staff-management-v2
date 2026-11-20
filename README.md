# SkyBar Staff Management V2.0

**Target production launch: 1 January 2027 (Asia/Kuala_Lumpur).**  
Source: **GitHub** · Public frontend: **Cloudflare Workers Static Assets** · Backend: **Supabase Edge Functions + PostgreSQL**  
No Google Apps Script or Google Sheets required.

## Current status

This repository contains the **V2 foundation**. It is not yet ready for staff production use.

| Feature | State |
|---|---|
| Responsive SkyBar dark navy / gold frontend | Implemented |
| Offline preview with sample data | Implemented |
| Staff ID + PIN custom server-side session | Implemented; needs real Supabase deployment/testing |
| Leave current-month / max 2 staff per date | Enforced in SQL; needs UAT |
| Calendar displays staff names and pending/approved | Implemented; needs UAT |
| AL by-year balance, entitlement, approved carry-forward and adjustment | Migration 004 + admin UI committed; requires SQL/Edge deployment & UAT |
| PH credit ledger, 2025/2026 historical credits, date-triggered 2027 PH | Migration 004 + admin UI committed; requires SQL/Edge deployment & UAT |
| Leave approval and cancel | Implemented; needs UAT |
| OT with 9-hour deduction, midnight crossings | Implemented; needs UAT |
| OT approval and original HR Excel export | **Not migrated yet** |
| Employee registration, position, ID change, resignation, PIN reset and safe delete | **Code committed; requires migration 003 + redeploy of Edge API + UAT** |
| Automated database backup and audit reporting | **Not configured yet** |

**Security notes:** The frontend contains no service role key, password or real staff records. All database access goes through an Edge Function. The browser only holds a short-lived opaque session token (sessionStorage). Database RLS is enabled, with no policies for public access. Admin and server security need a full penetration review before launch.

## Bulk PH Allocation — Migration 005

**Problem solved:** do not create 13 individual credit entries for every public holiday.

### Two administrator workflows

1. **Bulk yearly PH schedule** — Admin selects all active staff (or a subset) and pastes the whole year's holiday schedule. Each line uses `YYYY-MM-DD | Holiday Name | Days`; Excel three-column tab-separated paste also works. One confirmation allocates all scheduled holidays to all selected staff. Each credit unlocks on its actual date. Repeating the same schedule skips matching records instead of doubling credit.
2. **Historical PH opening balances** — Admin chooses 2025 or 2026, explicitly selects staff (or Select All), enters one outstanding opening balance per chosen staff, and saves once. Unticked staff are not modified; Apply to Selected Staff fills only ticked rows. Existing opening balances are updated, not duplicated. The table shows other PH credits already allocated for the year, so the administrator can avoid counting them a second time. `0` disables an unused opening credit; credits with usage history cannot be zeroed.

### Install order (the GitHub commits do not deploy Supabase automatically)

1. Supabase SQL Editor → run `supabase/migrations/20261120_005_bulk_ph.sql` **after 001–004**. This adds a nullable `bulk_key` to `ph_credits` and two authenticated, admin-only RPCs.
2. Supabase Edge Functions → `staff-api` → replace its code with the latest `supabase/functions/staff-api/index.ts` from this repo, then **Deploy updates**. Do not change the working `Verify JWT=OFF` setting.
3. Open Cloudflare: `https://skybar-staff-management-v2.texas-boiler.workers.dev/` and hard refresh.
4. Login ADMIN001 → AL & PH Management → **Allocate Annual PH Schedule** or **Historical PH Balances 2025 / 2026**.
5. Test with dummy employees only. To test idempotency, apply an identical schedule twice and confirm the second run reports `created=0` and `skipped=N`. Check the PH ledger for no duplicate records.

### Important rules

- PH must be earned before being available. Bulk schedule credits remain `LOCKED` until the specified holiday date (Malaysia time). The system does **not** guess holiday dates, replacement days or the hotel's official eligibility calendar.
- The historical balance grid is for **additional approved outstanding credit**, not a second copy of individual PH entries already added earlier; those credits are shown separately.
- 2026 opening balances added during 2026 are recorded as an **as-of date** (not an actual public holiday), and may include only PH already earned and approved.
- All batch changes are atomic, staff are limited to active STAFF accounts, actions are audited and 2027 live leave submissions remain locked until 2027-01-01.
- Test thoroughly before adding real staff data.

## AL & PH Management (next setup step)

1. In **Supabase SQL Editor**, run `supabase/migrations/20261120_004_al_ph_management.sql`. This updates the AL leave calculation and adds role-protected AL/PH administration RPCs. Existing employees, login and leave tables stay in place.
2. In Supabase **Edge Functions → staff-api**, replace the function's code with the latest `supabase/functions/staff-api/index.ts`, then **Deploy**. Keep Verify JWT **OFF**. This step is required; committing GitHub code does not deploy a Supabase Edge Function.
3. Allow Cloudflare Git auto-deployment to complete. Hard refresh `https://skybar-staff-management-v2.texas-boiler.workers.dev/`.
4. Login `ADMIN001`. Go to **AL & PH Management** (admin-only navigation). Choose **2027**. Set a dummy staff member's AL entitlement and carry-forward via **Set AL**.
5. Create one **2025 historical PH** (Historical / MANUAL) for dummy staff, and one **2027 future PH** (AUTO_DATE with correct future date).
6. Verify status shows historical **RELEASED**, future **LOCKED**, and totals in the admin ledger. Deactivate and reactivate an unused PH credit.
7. Confirm a normal staff account cannot open the AL/PH Admin page. Leave submissions remain blocked until go-live **1 January 2027**.

**Important:** The 2027 AL total is `2027 entitlement + carry-forward into 2027 + adjustment`. Do not copy the entire 2026 entitlement into 2027 carry-forward, or balances will be overstated. PH credit consumption is oldest-year-first, after it has been released. Dates are **not prefilled** because hotel-approved public holidays and replacement dates must be verified; the holiday name suggestions do not set dates.

AL/PH admin setup can be done before go-live, but this module is **not production verified** until SQL migration and UAT pass.

## Employee Management V2 (next setup step)

1. Supabase SQL Editor: run `supabase/migrations/20261120_003_employee_management.sql` **after** 001 and 002.
2. Supabase Edge Functions → `staff-api` → editor: replace function source with the latest `supabase/functions/staff-api/index.ts`, then deploy the updated version. Keep Verify JWT OFF for the existing custom-session design.
3. GitHub Pages publishes updated `assets/app.js` / `index.html` from the main branch automatically.
4. Hard refresh `https://kdems.github.io/skybar-staff-management-v2/` and log in as `ADMIN001`.
5. In Admin → Employee Management test creating a **dummy staff** account with an **8-digit PIN** and Position. Test Change ID, Mark Resigned, Reactivate, Reset PIN. A staff account with historical data must not be permanently deleted.
6. Do not import real staff personal records until all access control and recovery tests are completed.

The V2 SQL migration does **not** erase the existing administrator. Live Leave/OT submissions remain locked until 2027-01-01.

## Step 1 — GitHub Pages preview (no Supabase needed)

1. Repository → **Settings → Pages**.
2. Build and deployment: **Deploy from a branch**.
3. Branch: **main**; folder: **/(root)**.
4. Save.
5. Visit `https://kdems.github.io/skybar-staff-management-v2/`.
6. Click **Explore preview →** to inspect layout. The preview uses synthetic data and does not save records.

## Step 2 — Create a NEW Supabase project

Create a new Supabase project. Keep it separate from the older lost-access project.

1. In **Supabase SQL Editor**, paste and run `supabase/migrations/20261120_001_foundation.sql`.
2. Verify tables were created: `staff`, `staff_sessions`, `login_attempts`, `al_balances`, `ph_credits`, `leave_requests`, `leave_days`, `ph_usage`, `overtime_requests`, and `audit_log`.
3. **Do not share or commit any secret key or actual administrator PIN.**

To create the first admin, run **only in SQL Editor**, after changing the placeholder to a private 8-digit numeric PIN:

```sql
insert into public.staff(employee_id,name,pin_hash,position,role)
values (
  'ADMIN001',
  'System Admin',
  crypt('REPLACE_WITH_PRIVATE_8_DIGIT_PIN',gen_salt('bf',12)),
  'Outlet Manager',
  'ADMIN'
);
```

For a temporary test staff account, use `role='STAFF'` and a distinct Employee ID/PIN. Do not reuse the production PIN from earlier GAS versions.

## Step 3 — Deploy Edge Function

Use the Supabase CLI (requires Supabase account and project access):

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy staff-api --no-verify-jwt
```

The function uses Supabase project environment variables `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` on the server only. Verify both are available in your Supabase Edge runtime. **Never place them in a GitHub file or `config.js`.**

If a custom domain will be used, set the Edge secret `SKYBAR_ALLOWED_ORIGIN` to its exact origin (e.g. `https://staff.example.com`).

## Step 4 — Connect the public frontend

Edit `config.js` and set the **public Edge Function URL only**:

```js
apiUrl: "https://YOUR_PROJECT_REF.supabase.co/functions/v1/staff-api"
```

Commit the change. Reload the GitHub Pages URL, login using your temporary admin test account, and verify the dashboard. Keep submissions locked until 1 January 2027.

## Rules already enforced by the database

- Live submissions blocked until **1 January 2027**.
- Apply for leave **only in current month**, not earlier dates.
- **2 staff maximum per calendar date**, counting both PENDING and APPROVED.
- Full day = 1 unit; half-day AM/PM = 0.5 unit.
- AL credits counted across allocated years; used/reserved units reduce available balance.
- Historical PH can be entered with `MANUAL` release mode; dated PH unlocks on the actual date using Kuala Lumpur time.
- PH credits consumed oldest-first in one database transaction.
- OT = max(0, total shift duration − 9 hours); cross-midnight handled.
- No browser-native alert/confirm/prompt.

**Testing limitation:** The go-live lock currently also blocks admin test submissions. Before UAT, add a narrowly scoped staging bypass in a separate test database or use a staging date override strictly inside server-side database configuration. Do not remove the production lock.

## Upcoming milestones

1. Complete AL/PH UAT; implement controlled bulk allocation if required.
2. Full OT approvals and downloadable HR Excel claim matching `OT form.xlsx`.
3. Data validation, user acceptance testing with three simulated staff.
4. Backups, operational runbook and security review.
5. Production cutover, target **1 Jan 2027**.
