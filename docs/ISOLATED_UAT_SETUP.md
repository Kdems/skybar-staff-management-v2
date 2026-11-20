# SKYBAR STAFF MANAGEMENT V2 — ISOLATED LEAVE UAT SETUP

**Branch:** `uat-leave-2026`  
**Environment:** new separate Supabase project + separate Cloudflare Worker  
**Production URL:** unchanged  
**Production Supabase reference:** `qamckmvukksiufucpetx` — NEVER use it for staging.  
**Production go-live lock:** **1 January 2027**, must remain unchanged.

## Never do these things

- Do not run `supabase/staging/uat_leave_bypass_only.sql` inside the live Supabase project.
- Do not deploy the UAT branch to the existing production Worker `skybar-staff-management-v2`.
- Do not copy live employee data, administrator PINs, session tokens or service-role keys.
- Do not merge the staging branch into main while it includes an early-submission bypass.
- Do not store a Supabase service-role key, password or token in GitHub or frontend `config.js`.

## 1 — Create a fresh staging database (first human step)

1. Supabase Dashboard → **New project**, choose a distinct project name such as **skybar-staff-v2-uat**.
2. Save its new **Project reference** from Settings → General. It **must differ** from `qamckmvukksiufucpetx`.
3. Open staging SQL Editor and run these migration files in order, from the `uat-leave-2026` GitHub branch:
   - `20261120_001_foundation.sql`
   - `20261120_002_login_pgcrypto_search_path.sql`
   - `20261120_003_employee_management.sql`
   - `20261120_004_al_ph_management.sql`
   - `20261120_005_bulk_ph.sql`
4. While the staging database is **still empty (no staff/accounts)**, run **only there** `supabase/staging/uat_leave_bypass_only.sql`. It refuses to run against a database containing existing staff/leave/PH/AL/OT data.
5. Use SQL Editor to create UAT-only ADMIN001 with a **different private 8-digit PIN**. Never expose the PIN in chat or GitHub. A test staff account may be registered later through the Admin UI.
6. In staging Admin → AL & PH Management, allocate AL for **2026** test dates; don't assume the 2027 opening AL will be available before January. Add a 2025 historical PH credit if testing PH leave.

## 2 — Deploy a separate Supabase Edge Function

1. Supabase Dashboard → staging project → Edge Functions → create `staff-api`, paste the source from **this branch** `supabase/functions/staff-api/index.ts`.
2. Deploy updates and leave **Verify JWT OFF** (custom staff session auth). Use staging project's built-in Supabase secrets only, not production keys.
3. When staging Cloudflare worker has been deployed, set Supabase Edge secret `SKYBAR_ALLOWED_ORIGIN` to that **exact** HTTPS origin and redeploy if needed.

## 3 — Deploy a separate Cloudflare UAT Worker

1. Cloudflare Dashboard → Workers & Pages → **Create Worker** with Git connection to `Kdems/skybar-staff-management-v2`, choose branch **`uat-leave-2026`**.
2. Worker name MUST match `wrangler.jsonc`: `skybar-staff-management-v2-uat`. **Do not select the existing production Worker.**
3. Build command: `bash scripts/build-uat.sh`.
4. Deploy command: `npx wrangler deploy`.
5. `wrangler.jsonc` uses `assets.directory = "./.uat-dist"`, so only `index.html`, `config.js`, `assets/app.js` and `assets/styles.css` are public. No SQL migrations or server code become public assets.
6. After staging Supabase project reference is known, edit **only staging branch** `config.js` with `https://STAGING_PROJECT_REF.supabase.co/functions/v1/staff-api`; this is a PUBLIC API URL, not a secret.
7. Hard refresh the new, verified UAT Worker URL, verify the prominent **UAT STAGING** banner, and login with UAT-only credentials.

**Note:** Cloudflare Git Builds might create a branch Preview version when connected to the production Worker. A preview does NOT itself create a new isolated database. Do not use a generic preview URL with the production API. This guide uses a separate Worker AND a separate Supabase project.

## 4 — UAT test cases (after setup)

- Log in UAT TEST002, submit a November/December 2026 AL request on a remaining date within current month; expect **PENDING**.
- Log in UAT ADMIN001, approve; expect **APPROVED**, daily slot reserved, AL balance reduced.
- On another UAT request, reject or cancel; expect slot and available balance returned.
- Submit overlapping leaves for three separate dummy staff on same date; first two pending/approved count, third must be blocked.
- Submit a historical available PH leave; expect oldest-year-first consumption.
- Confirm future-dated PH remains **LOCKED**.
- Confirm the live production website still rejects pre-2027 leave requests (do not delete or modify production SQL).

## Approval gates

- Staging project exists and its project ref differs from production.
- SQL migrations installed in staging only; UAT-only early leave SQL installed there only.
- Staging Edge Function uses staging project and origin.
- Staging Worker is isolated from the production Worker and shows the UAT banner.
- Complete tests with dummy staff, then remove test data before production launch.

**Do not consider staging active just because these GitHub files exist.** Manual creation/deployment of the separate Supabase and Worker projects is still required.
