# SkyBar Staff Management V2 — Migration Completion & Release Runbook

**Go-live target: 1 January 2027 (Malaysia time).**
**Change policy:** Complete migration first; run end-to-end UAT only after all features are installed.
**Do not modify the existing go-live lock.**

## 1. Implementation status — GitHub main

| Domain | Source status | Still required |
|---|---|---|
| Employee ID + PIN, staff lifecycle | Implemented; basic user UAT previously passed | Production review |
| AL entitlement + 2027 carry-forward | Implemented and basic user UAT passed | Annual reconciliation |
| PH bulk annual schedule, historical 2025/2026 and selected-staff grid | Implemented; user UAT passed | Calendar and entitlement reconciliation |
| Leave request / Pending / Approval / Calendar / 2 staff limit | Implemented | End-to-end UAT after 2027 lock bypass in isolated staging |
| **Admin Edit Leave Type**: AL, PH, EL, OFF | **Migration 006 + Edge API + frontend committed** | SQL 006, Edge deploy, UAT |
| **Admin-only OFF** | Server-side admin check, staff dropdown does not contain OFF; OFF keeps leave slot and does not debit AL/PH | SQL 006, Edge deploy, UAT |
| OT submission and automatic 9h deduction | Implemented | End-to-end UAT |
| **OT approval / reject / pending cancel** | **Migration 007 + Edge API + frontend committed** | SQL 007, Edge deploy, UAT |
| **OT print claim / Excel XLSX exports** | Implemented, generic document format | Confirm exact hotel's HR template before claiming template parity |
| **Reports & Audit** | Admin-only paginated exports to native XLSX | Deploy latest Edge API, UAT |
| Automated backups | **Not configured by source code** | Check Supabase plan backups and establish protected recovery exports |
| Security audit / release operations | Engineering checklist below | Execute with authorized admin and hotel IT |

## 2. Single combined upgrade — production project

**IMPORTANT:** Confirm project reference is the production project \`qamckmvukksiufucpetx\`. 
Three schema migrations are required on top of previously applied migrations 001–005:

1. Back up the current database before any schema changes (Supabase backups or managed SQL export).
2. SQL Editor: run \`supabase/migrations/20261121_006_admin_leave_edit_offday.sql\`.
3. SQL Editor: run \`supabase/migrations/20261121_007_overtime_approval.sql\`.
5. Edge Functions → \`staff-api\` → replace with **latest** \`supabase/functions/staff-api/index.ts\`, then deploy ONCE.
6. Cloudflare Git build: confirm deployment of GitHub \`main\` to existing Worker \`skybar-staff-management-v2\` and that \`.assetsignore\` prevents migrations, API code and docs from becoming public website assets.
7. **Never switch Verify JWT to ON**, unless replacing the current custom Employee ID+PIN session system with a Supabase Auth JWT workflow. The current app validates sessions server-side.
8. Do not run the staging-only \`supabase/staging/uat_leave_bypass_only.sql\` against this project. Production go-live lock **2027-01-01** must remain.

**Rollback:** Before proceeding, export a schema/database backup and retain old Edge Function code from GitHub history. SQL 006 extends allowed leave types and SQL 007 adds fields/RPC; do not drop new constraints/columns merely to roll back frontend. Review data created after deployment before any rollback.

## 3. Leave correction business rules

- Staff may submit only AL, PH or EL. Staff **cannot** submit or select OFF via UI or database submit RPC.
- Only active ADMIN can convert a Pending or Approved leave to AL, PH, EL or **OFF**.
- Admin must enter a **reason**. Changes record old/new type, actor, dates and units in \`audit_log\`.
- Dates, staff, units, request status, and calendar slot remain unchanged during type edits. OFF still counts towards max **2 staff/day**.
- PH → AL: reserved PH credit is automatically released; AL is allowed only when the corresponding year's available entitlement is enough.
- AL → PH: AL balance is automatically freed; the transaction must acquire enough *already unlocked* PH credits, oldest first.
- AL/PH → OFF or EL: neither AL nor PH balance is debited. Conversion back to AL/PH enforces balance.
- Rejected and Cancelled requests are **not editable** through the correction RPC. They must not be resurrected via this workflow.
- Every conversion is one database transaction under the same advisory lock as leave submissions and PH credit edits. Failure rolls back the whole correction.

## 4. Overtime rules

- Staff submit OT for the last 31 days, with shift start, shift end, claim type, reason and approver.
- Working baseline: 9 hours; overtime is measured as elapsed shift minutes minus 540.
- Admin can Approve or Reject a **Pending** claim. Rejection requires an explanation; staff can Cancel their own Pending claim.
- Already decided OT cannot be approved, rejected or cancelled again via the API.
- Staff can print a generic claim form. The original hotel OT `.xls` was supplied and its cell layout, labels, merges, embedded logo and signatures inspected. A macro-free `.xlsx` reconstruction has been produced. SQL 008 enables Admin to upload the approved workbook through Admin → OT Approval & Reporting → Upload / Replace Template. Exact visual parity should be reviewed in Excel during combined UAT.
- Admin reports are available as XLSX files via client-side export. The exporter is local and does not send data to third-party CDNs.

## 5. Security and operational readiness before staff access

- Verify Cloudflare **public assets only**: \`/\`, \`/config.js\`, \`/assets/app.js\`, \`/assets/styles.css\`. Access to \`/supabase/migrations/...\`, \`/supabase/functions/...\`, \`/docs/...\` must return 404.
- Only the public Edge Function URL belongs in \`config.js\`; never use service role keys there.
- Change dummy/admin PINs; delete TEST accounts only when no operational history, otherwise mark INACTIVE. Avoid deleting history.
- Restrict staff account creation and PIN reset to Admin; audit access and reset actions.
- Confirm backup frequency and recovery plan (depends on Supabase subscription). Keep encrypted/exported backup outside public GitHub.
- Establish HR-approved AL, PH, replacement PH and unused balance sources before data import.
- Retain \`audit_log\` and avoid bulk wiping historical leave and OT data.
- Reconcile 2026 AL carry-forward into the 2027 row; never copy full 2026 entitlement as carry-forward.
- Do not enable live submissions before 1 January 2027.

## 6. One combined UAT after migration

Use a **fresh separate Supabase project and separate Cloudflare Worker**, not a production bypass.

1. Register three dummy staff and allocate 2026/2027 AL and historical/future PH.
2. Submit AL, PH and EL via staff UI and reject direct OFF submission attempts.
3. Admin changes AL→PH, PH→AL, AL→OFF, OFF→PH, including Pending & Approved status. Verify refunds, debits, and audit.
4. Check insufficient AL/PH protection and rollback on failed admin edits.
5. Verify max 2 staff/day across Pending, Approved and OFF.
6. Cancel/reject a request, verify calendar slot and balances return.
7. Submit OT including midnight crossing; approve, reject, cancel Pending, verify 9h deduction and notes.
8. Export leave, OT, employee, AL, PH and audit XLSX reports; open in Excel.
9. Upload the approved macro-free OT workbook as Admin; download a staff OT form and compare against original layout and printout, including monthly totals and signatures.
10. Check login, PIN reset, reactivation, session invalidation and Admin-only routes.
11. Verify main production lock remains active until 1 January 2027, and the production database has no UAT-only SQL.
12. Complete disaster-recovery rehearsal and management/IT sign-off.

**Status distinction:** source code committed is NOT the same as SQL applied, Edge Function redeployed, Cloudflare re-built, or live acceptance passed.

## OT original template — Migration 008

- Original user file: Overtime Form.xls, a 2009-era Excel workbook containing VBA streams.
- All new OT downloads use one admin-uploaded .xlsx template stored in Supabase privately; only authenticated staff may retrieve it.
- Macro-free reconstruction is available as a conversation download. For exact visual parity, use Excel Save As to .xlsx from the original workbook (preserving embedded drawings, print settings, fonts), then upload the approved copy via Admin.
- Admin template updates are audited and do not alter claim records. Staff cannot change the template.
- The system fills employee identity, period 11th–10th, actual shift, OT from/to, rates x1.5/x2.0/x3.0, Off Day/Compulsory PH and preparation date. Template totals and original approval/signature positions remain.
- Fields for night shift, split shift and certification are left blank when not captured by the OT system; do not fabricate details.
- If multiple OT claims exist on one calendar date, the downloader stops rather than silently dropping extra records; use the full OT register for reconciliation.
- Do not place OT template in public Cloudflare static assets. Run SQL 008 and deploy latest Edge API before uploading template.
