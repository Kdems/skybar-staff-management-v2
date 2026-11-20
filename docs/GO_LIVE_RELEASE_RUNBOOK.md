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
| **HR OT form + XLSX reports** | Source workbook layout, approved-only Admin export and employee-named sheet committed | Exact Microsoft Excel Print Preview comparison during final UAT |
| **Reports & Audit** | Admin-only paginated exports to native XLSX | Deploy latest Edge API, UAT |
| Automated backups | **Not configured by source code** | Check Supabase plan backups and establish protected recovery exports |
| Security audit / release operations | Engineering checklist below | Execute with authorized admin and hotel IT |

## 2. One combined release — after backup

**No further individual feature UAT until all V2 source and database migrations are complete.**

1. Confirm this is the current SkyBar V2 production Supabase project. Back up the existing data first, and retain a known-good copy of the deployed Edge Function.
2. Open Supabase SQL Editor and run **only** `supabase/migrations/20261121_006_009_final_combined_release.sql` ONCE. It applies 006, 007, 008 and 009 atomically, refuses an isolated UAT database, and checks that the 1 January 2027 submission lock still exists.
3. In Supabase Edge Functions → `staff-api`, replace with the latest `supabase/functions/staff-api/index.ts` from GitHub `main` and deploy once. Keep Verify JWT OFF for the existing custom staff session authentication.
4. Cloudflare Git deploy: verify `main` and the committed `wrangler.jsonc` are used, and the **strict** `.assetsignore` allows exactly `index.html`, `config.js`, `assets/app.js`, `assets/styles.css`, `assets/ot-form-generator.js`. No `/supabase/`, `/docs/`, `/README.md` or `/wrangler.jsonc` may be publicly retrievable.
5. Admin → OT Approval & Reporting → Upload / Replace Template → upload `SkyBar_OT_Master_Original_Format.xlsx`, based on the real source `OT form.xlsx`. This workbook contains the original sheet, embedded hotel logo, 28 merge ranges, fonts and print settings. No employee data is loaded at this step.
6. Keep `submit_leave_v2` and `submit_overtime_v2` locked before 2027-01-01. Never run `supabase/staging/uat_leave_bypass_only.sql` against production.
7. Only **after** all of these changes are deployed: perform one combined UAT in a separate database/Worker, review OT print parity in Microsoft Excel, and obtain HR/IT sign-off before opening staff production.

**Do not run 006, 007, 008 or 009 separately after the combined release.** The four original files remain in GitHub for source transparency and troubleshooting, not as an additional install step.

**Rollback:** Record exact previous Edge/Cloudflare versions before deployment and retain an approved DB backup. The combined SQL adds new table/function/columns and expands a check constraint; do not blindly drop the new schema if transactions were recorded after the upgrade.

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
- Only Admin can download an approved-only HR OT workbook for a selected employee and 16th–15th payroll period; resigned staff remain selectable. The original hotel OT `.xls` was supplied and inspected. An approximate reconstruction was rejected for fidelity. Always upload an `.xlsx` converted from the ORIGINAL `.xls` using Microsoft Excel Save As; the tool now preserves original visual/style parts and checks template identity. SQL 008 enables Admin to upload the approved workbook through Admin → OT Approval & Reporting → Upload / Replace Template. Exact visual parity should be reviewed in Excel during combined UAT.
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
9. Upload the approved macro-free OT workbook as Admin; download a staff OT form and compare against original layout and printout, including original formula cells (if any) and signature areas.
10. Check login, PIN reset, reactivation, session invalidation and Admin-only routes.
11. Verify main production lock remains active until 1 January 2027, and the production database has no UAT-only SQL.
12. Complete disaster-recovery rehearsal and management/IT sign-off.

**Status distinction:** source code committed is NOT the same as SQL applied, Edge Function redeployed, Cloudflare re-built, or live acceptance passed.

## OT original template — Migration 008

- Original user file: Overtime Form.xls, a 2009-era Excel workbook containing VBA streams.
- All new OT downloads use one admin-uploaded .xlsx template stored in Supabase privately; only authenticated staff may retrieve it.
- Macro-free reconstruction is available as a conversation download. For exact visual parity, use Excel Save As to .xlsx from the original workbook (preserving embedded drawings, print settings, fonts), then upload the approved copy via Admin.
- Admin template updates are audited and do not alter claim records. Staff cannot change the template.
- The system fills employee identity, period 16th–15th, actual shift, OT from/to, rates x1.5/x2.0/x3.0, Off Day/Compulsory PH and preparation date. Any formulas present in the uploaded Excel master and all original HR approval/signature positions remain; no new totals are invented.
- Fields for night shift, split shift and certification are left blank when not captured by the OT system; do not fabricate details.
- If multiple OT claims exist on one calendar date, the downloader stops rather than silently dropping extra records; use the full OT register for reconciliation.
- Do not place OT template in public Cloudflare static assets. Run SQL 008 and deploy latest Edge API before uploading template.

### Strict source parity changes

- Actual source period is **16th of month to 15th of next month**, not 11th–10th. Original worksheet rows 15–30 are reserved for days 16–31 and rows 31–45 for days 1–15. Short first months leave unused rows blank; merged month label blocks are not modified.
- Original source has `OVERTIME (OT)` in A6. The Admin uploader now validates this, the exact source merge ranges, image/drawing and print settings. Wrong approximation templates are rejected.
- All former sample shift/OT inputs in the uploaded workbook are cleared when generating a download; all other workbook parts, images, borders, HR instructions and approval sections remain unchanged.
- Exact equality of PDF/printed appearance is still dependent on the font availability, Excel version, printer drivers and Excel Save As conversion. Confirm using Excel's original Print Preview during combined UAT; do not claim verified 100% visual equivalence before that.

- The Admin uploader now strips historical example shift entries and identifying values automatically before storing the workbook; employee data is added only during authorized download.

## V1.7 parity completed in migration 009

- Admin can toggle **OT Approver / Manager / Supervisor** on any employee. The staff **Instructed By** list includes active flagged employees, not just ADMIN accounts; staff must select one when submitting OT.
- Duplicate Pending/Approved OT for one staff and date is prohibited via atomic server check and partial unique index. Resubmission after rejection/cancellation is allowed.
- HR OT form export is **Admin-only**, selects **employee (including Resigned/Inactive)** and **cycle month (16th to 15th)**, and includes **APPROVED claims only**. Position is mandatory; no claim is silently omitted.
- Output worksheet tab is renamed to the employee name (Excel-safe, maximum 31 characters). Certified By and signature blocks remain blank for manual HR approval, as per V1.6.2.
- Admin can cancel Approved OT with mandatory reason and audit; Staff can cancel only Pending OT. Cancelled claims are excluded from future HR downloads.
- The per-staff OT records list on Admin dashboard is limited, so export uses its own authenticated period query and does not truncate approved payroll items.
- Older file `20261121_006_008_combined_release.sql` is superseded. The ONLY active production release file is `20261121_006_009_final_combined_release.sql`.
