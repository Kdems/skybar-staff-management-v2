# SkyBar V2 — Operational readiness

Target go-live: 2027-01-01 (Malaysia time). SQL 001–009, Edge deployment, Cloudflare rollout and original OT master upload were reported complete by the project owner. Full UAT and restore rehearsal are still pending.

## 1. Backup before operational setup
- In the existing production Supabase project, open Database → Backups and record the latest available recovery point.
- Paid plans provide scheduled daily backups; Free has no guaranteed accessible automatic backup. Use a logical dump via Supabase CLI (roles, schema and data) or an authorized PostgreSQL backup method. Official instructions: https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore and https://supabase.com/docs/guides/platform/backups.
- Keep backups encrypted, access restricted, and outside GitHub and Cloudflare. They contain employee information, PIN hashes, session-token hashes, and the OT template stored in PostgreSQL.
- Retain source revisions and the original OT master separately. Database backup alone does not restore Edge deployment, secrets or Cloudflare configuration.
- Schedule daily backups during active use and a backup before migration or mass allocation. Agree retention and recovery goals with authorized management.
- Rehearse restore to a separate controlled project, never over live data. Do not make restored employee records available to the UAT frontend; use an independent dummy-only UAT environment instead.

## 2. Read-only readiness checks
Run supabase/checks/production_readiness_readonly.sql in SQL Editor. Examine any REVIEW rows. It checks table presence, RLS, public RPC grants, launch date guard text, staging marker, stored OT template, approvers, staffing and selected data invariants. It is not proof of complete security or UAT. No rows are altered.
Also confirm actual Cloudflare public assets and ensure backend paths return 404; check unauthorized API access in the final UAT. Keep secrets out of browser and GitHub.

## 3. Final UAT
Use a separate project and Worker with dummy data only, current source and schema, and a separate staging-specific override for both submission date locks if testing before 2027. Never modify production locks. Validate staff login, roles, leave/PH/AL/OFF conversions, calendar slots, OT calculations/approvers/approval/cancellation, report exports, and Microsoft Excel print comparison to the original HR template.

## 4. Data and go-live
Reconcile the 13-staff roster with HR, 2027 AL rows, approved AL carry-forward, outstanding 2025/2026 PH, and approved 2027 PH schedule. Confirm approver list. Deactivate TEST accounts with history; only delete confirmed unused accounts using the authorized Admin feature. Review all test allocations and request histories before making corrections; do not mass-delete records. Confirm approved recovery point, full UAT sign-off, and production date guard before staff rollout.

No backup job, restore, data deletion, or live security validation was performed by writing this document.
