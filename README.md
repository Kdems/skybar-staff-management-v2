# SkyBar Staff Management V2.0

**Target production launch: 1 January 2027 (Asia/Kuala_Lumpur).**  
Frontend: **GitHub Pages** · Backend: **Supabase Edge Functions + PostgreSQL**  
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
| AL balance calculation | Implemented; admin allocation UI pending |
| PH dated credits, historical carry-forward and unlock rules | Implemented in database; admin entry UI pending |
| Leave approval and cancel | Implemented; needs UAT |
| OT with 9-hour deduction, midnight crossings | Implemented; needs UAT |
| OT approval and original HR Excel export | **Not migrated yet** |
| Employee registration, position, ID change, resignation, PIN reset and safe delete | **Code committed; requires migration 003 + redeploy of Edge API + UAT** |
| Automated database backup and audit reporting | **Not configured yet** |

**Security notes:** The frontend contains no service role key, password or real staff records. All database access goes through an Edge Function. The browser only holds a short-lived opaque session token (sessionStorage). Database RLS is enabled, with no policies for public access. Admin and server security need a full penetration review before launch.

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

1. Administrative employee management and PH/AL bulk allocation.
2. Full OT approvals and downloadable HR Excel claim matching `OT form.xlsx`.
3. Data validation, user acceptance testing with three simulated staff.
4. Backups, operational runbook and security review.
5. Production cutover, target **1 Jan 2027**.
