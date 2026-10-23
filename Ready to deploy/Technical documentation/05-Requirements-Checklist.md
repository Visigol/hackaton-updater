# QA Platform: Requirements Verification Checklist

Every requirement in the "AI QA Tool: Solution Architecture and Stack" document, with its honest status and the way
to prove it. Use this to see what is done, what differs from the document, and what is still open.

Date: 2026-10-20.

## How to read the statuses

| Status | Meaning |
|---|---|
| **MET** | Built, and you have seen it work in your own environment |
| **BUILT** | Implemented in the code, but not yet run in your environment. Run the check before claiming it |
| **VERIFY** | Depends on how your Supabase project is configured. Run the check to find out |
| **DEVIATION** | The goal is met, but with a different technology or approach than the document proposed |
| **PARTIAL** | Part of the requirement is covered; the gap is stated |
| **NOT BUILT** | Not implemented |

"MET" is used only for things you have run: sign-in, tenant isolation (read, URL, forged write), upload, the worker
audit, and creating a second tenant.

## Before the BUILT items can be claimed

1. Run `supabase\admin_setup.sql` in the Supabase SQL Editor (policies, activity log, `save_rubric()`).
2. Set `SUPABASE_SERVICE_ROLE_KEY` on Vercel and redeploy the six web files.
3. Walk through the pitch once. Change **BUILT** to **MET** as each part works.

---

## 1. Guiding principle: every table, call and job carries a tenant

| # | Requirement | Status | Evidence and how to verify |
|---|---|---|---|
| 1.1 | Every tenant table has `tenant_id` | **MET** | `select table_name from information_schema.columns where table_schema='public' and column_name='tenant_id' group by 1 order by 1;` lists every tenant table |
| 1.2 | Every API call carries the tenant | **BUILT** | The admin API reads the tenant from the caller's own `users` row and ignores any tenant in the request. Test: call it with a supervisor's session and get 403 |
| 1.3 | Every background job carries the tenant | **MET** | `jobs.tenant_id`; the worker sets the tenant per transaction. `select tenant_id, status, count(*) from public.jobs group by 1,2;` |

## 2. Multi-tenancy model

| # | Requirement | Status | Evidence and how to verify |
|---|---|---|---|
| 2.1 | Pool model: shared tables with `tenant_id` and Row-Level Security | **MET** | `select relname, relrowsecurity from pg_class where relnamespace='public'::regnamespace and relkind='r';` is true for tenant tables |
| 2.2 | A query can only see its own tenant's rows, enforced by the database | **MET** | You ran three tests: other-bpo saw no boltverse rows; the address change redirected; a forged insert returned HTTP 403 |
| 2.3 | Upgrade path to schema or database per tenant | **PARTIAL** | Structurally ready (every query carries the tenant), described in the SOP. No migration tooling exists, which the document says is a later task |

## 3. Tenant hierarchy

| # | Requirement | Status | Evidence and how to verify |
|---|---|---|---|
| 3.1 | Tenant (vendor) record | **MET** | `select id, name, slug from public.tenants;` shows boltverse and other-bpo |
| 3.2 | Rubric versioned: one active version plus history | **BUILT** | The worker already reads the active version. The editor and `save_rubric()` create versions; check with `select tenant_id, version, is_active from public.rubrics order by 1,2;` after saving once |
| 3.3 | Each tenant has its own rubric copy, seeded from a default | **VERIFY** | `select t.slug, r.version from public.tenants t left join public.rubrics r on r.tenant_id=t.id and r.is_active;` Every tenant must show a version. A missing one means the seed did not run |
| 3.4 | Knowledge base (policy documents, vector-indexed) | **PARTIAL** | Admins upload policy documents as text (Knowledge base screen); they are masked, stored per tenant and read by the research agent. They are matched to checks by shared keywords. **There is no vector index** (Chrome's built-in AI offers no embeddings model), which the requirement names. Needs `supabase/platform_setup.sql` |
| 3.5 | Users with roles scoped to the tenant | **MET** | `select u.email, u.role, t.slug from public.users u join public.tenants t on t.id=u.tenant_id;` The admin screen to manage them is **BUILT** |
| 3.6 | Transcripts / interactions | **MET** | Uploads and the watcher both store them under the right tenant |
| 3.7 | Audit scores | **MET** | The worker wrote scores that the dashboard shows |
| 3.8 | Pending rubric changes awaiting approval | **BUILT** | The research agent files proposals as PENDING `rubric_change_requests`; an admin approves (saves a new rubric version) or rejects them on the Rubric screen. Nothing changes without approval. Needs `platform_setup.sql` and a run on the real model |
| 3.9 | Performance reports | **BUILT** | The `qa_report` agent network writes coaching advice from statistics computed in code and stores it in `performance_reports`; the Reports screen shows it (agents see their own). Needs `platform_setup.sql` and a run on the real model |
| 3.10 | Nothing shared across tenants except code and infrastructure | **MET** | All tenant tables use the same policies; the only cross-tenant statement is the worker's job claim (see 8.2) |

## 4. High-level architecture and request flow

| # | Requirement | Status | Evidence and how to verify |
|---|---|---|---|
| 4.1 | User signs in and the tenant is resolved from their identity | **MET** | After sign-in the page opens `/t/<your-slug>/dashboard`; the tenant comes from the user's row, not the address |
| 4.2 | The orchestrator loads that tenant's rubric | **MET** | `job_worker._load_context` reads the active rubric under the tenant's RLS scope |
| 4.3 | The orchestrator loads that tenant's knowledge base | **BUILT** | The research agent receives the tenant's documents (under that tenant's database scope) with the corrections. The audit itself does not read the knowledge base; it learns through approved rubric changes |
| 4.4 | Results are written to shared tables, and the vendor can only read its own | **MET** | Cross-tenant read test |
| 4.5 | One codebase, one deployment, N tenants | **MET** | A second tenant was added with one SQL call and no code change |

## 5. Tech stack

| # | Layer | Document says | What was built | Status |
|---|---|---|---|---|
| 5.1 | API | FastAPI | FastAPI | **MET** |
| 5.2 | Auth | Clerk or Supabase Auth | Supabase Auth, with tenant and role in `public.users` rather than the "organizations" feature | **DEVIATION** |
| 5.3 | Orchestration | LangGraph or CrewAI, 5 agents | **Neuro SAN** (the framework required by the hackathon), with Gemini Nano as the model. **4 of the 5 agents are built:** audit (`qa_audit`), performance (`qa_report`), research (`qa_research`) and chat assistant (`qa_assistant`), plus the `qa_platform` router that shows them together in the Studio. The fifth, the email/notification agent, is **not built**. All were validated end to end on the real Neuro SAN server with a scripted model; running them on the real Gemini Nano is the remaining step | **BUILT** |
| 5.4 | LLM | Claude API | On-device Gemini Nano through Chrome | **DEVIATION** (privacy and no per-call cost) |
| 5.5 | Relational DB | PostgreSQL | Supabase PostgreSQL | **MET** |
| 5.6 | Vector store | pgvector | The extension and column are defined in `schema.sql`; nothing uses them yet | **VERIFY** (`select extname from pg_extension where extname='vector';`) |
| 5.7 | Object storage | S3-compatible, tenant-prefixed | Not used; transcripts are rows | **DEVIATION** |
| 5.8 | Background jobs | Celery + Redis or a simple queue | A Postgres `jobs` table with `claim_job()` and retries | **DEVIATION** |
| 5.9 | Email | Resend or SendGrid | None | **NOT BUILT** |
| 5.10 | Frontend | Next.js + Tailwind | FastAPI-served HTML and JavaScript (no Node.js available) | **DEVIATION** |
| 5.11 | Deploy | Render or Railway for backend, Vercel for frontend | Vercel for the web app; the audit engine runs on a local machine | **PARTIAL** |
| 5.12 | Path-based tenant routing | `/t/<slug>/dashboard` | `/t/<slug>/dashboard` | **MET** |

## 6. Core data model

| # | Table | Status | How to verify |
|---|---|---|---|
| 6.1 | `tenants` | **MET** | In use |
| 6.2 | `users` (id, tenant_id, email, role) | **MET** | In use; roles admin, supervisor, team_lead, agent |
| 6.3 | `rubrics` | **MET** | In use by the worker. `approved_by` is not filled in by the app (see 8.3 for the audit trail instead) |
| 6.4 | `rubric_change_requests` | **BUILT** | Written by the research agent, read and decided by admins. Created or completed by `platform_setup.sql` |
| 6.5 | `knowledge_base_docs` | **BUILT** | Written by admins (text content), read by the research agent. The `embedding` column is not used |
| 6.6 | `transcripts` | **MET** | In use (your database also has extra columns such as `external_ref`) |
| 6.7 | `audit_scores` (plus `passed`, `critical_fail`) | **MET** | In use |
| 6.8 | `performance_reports` | **BUILT** | Written by the worker, read by staff and by the agent concerned |
| 6.9 | `notifications_log` | **NOT BUILT** | No notifications are sent |
| 6.10 | RLS policy on every tenant table | **MET** | `select tablename, policyname, cmd from pg_policies where schemaname='public' order by 1,3;` |
| 6.11 | API sets `app.current_tenant` at the start of each request | **DEVIATION** | The web app resolves the tenant with `current_tenant()` from the user's JWT; the worker sets `app.current_tenant` per transaction. Same guarantee, and it works with Supabase's connection pooling |

To see which of the unused tables exist in your database:
`select table_name from information_schema.tables where table_schema='public' order by 1;`

## 7. Vendor onboarding flow

| # | Step | Status | Evidence and how to verify |
|---|---|---|---|
| 7.1 | Admin creates a tenant record (first-class action, not a hand-edited config file) | **MET** | `select public.create_tenant('Name','slug');` created other-bpo. It is an SQL call, which the document allows for the MVP |
| 7.2 | System seeds a default rubric for the tenant | **VERIFY** | See 3.3 |
| 7.3 | Admin uploads knowledge-base documents | **BUILT** | Knowledge base screen; see 3.4 for the limits |
| 7.4 | Admin invites users, each tenant-scoped | **BUILT** | Users and roles screen: creates the login and links it to the admin's tenant. Uses a temporary password rather than an email invite |
| 7.5 | Vendor is live: transcripts submitted, scores flowing | **MET** | Upload and watcher both lead to scores |

## 8. Security and compliance

| # | Requirement | Status | Evidence and how to verify |
|---|---|---|---|
| 8.1 | Encryption at rest | **VERIFY** | Provided by managed Supabase Postgres by default. Confirm in your plan's documentation and note it |
| 8.2 | No "admin bypass" query path that skips tenant filtering | **PARTIAL** | Users' own requests always go through RLS. Two privileged paths exist, both narrow: the worker's `claim_job()` (cross-tenant by necessity, returns one job, then everything runs scoped to that tenant), and the admin API's service-role key (used only server-side, only after verifying the caller is an admin, and every query is filtered by that admin's tenant). Neither is reachable from the browser as a general-purpose query |
| 8.3 | Log every rubric change with tenant and actor | **BUILT** | `save_rubric()` writes to `audit_trail` with tenant, actor and version. Verify: save a rubric, then `select action, actor_email, detail, created_at from public.audit_trail order by created_at desc limit 5;` |
| 8.4 | Log every notification with tenant | **NOT BUILT** | No notifications exist. The `audit_trail` also records user changes, uploads, edits, reviews and deletions |
| 8.5 | The audit log cannot be altered | **BUILT** | `audit_trail` has insert and select policies only, with no update or delete policy. Verify with `select policyname, cmd from pg_policies where tablename='audit_trail';` |
| 8.6 | Role-based access within a tenant | **MET** (policies) / **BUILT** (admin screens) | Policy output shows role checks. Supervisor cannot reach Users or Rubric, and the Users API refuses non-admins |
| 8.7 | Agents cannot see other agents' scores | **MET** | The transcripts policy allows agents only rows where `agent_name = current_agent_name()`. Verify by signing in as an agent user |
| 8.8 | Sensitive data (PII, card numbers) protected | **MET** | Masked before storage, and again by the worker. Verify with the masked-text query in the pitch |

## 9. MVP scope

| # | In the MVP | Status |
|---|---|---|
| 9.1 | One shared Postgres instance, pool model with RLS | **MET** |
| 9.2 | Path-based tenant routing | **MET** |
| 9.3 | Manual or admin-form tenant onboarding | **MET** (SQL call) |
| 9.4 | Single-region deployment | **MET** |
| 9.5 | Rubric changes approved by one admin role | **BUILT** (admin edits directly; each change is versioned and logged) |
| 9.6 | The "multi-tenant ready" test: add the next tenant without touching the isolation layer | **MET** (other-bpo was added with one SQL call) |

## 10. Open decisions: how they were resolved

| # | Decision | Resolution |
|---|---|---|
| 10.1 | Auth provider | Supabase Auth |
| 10.2 | Vector store | pgvector (defined, not yet used) |
| 10.3 | Who approves rubric changes | One admin role per tenant, directly, with versions and an activity log |

---

## Summary

| Status | Count |
|---|---|
| MET | 32 |
| BUILT (needs your run) | 14 |
| VERIFY (depends on your Supabase) | 4 |
| DEVIATION (goal met differently) | 6 |
| PARTIAL | 4 |
| NOT BUILT | 3 |

### What would close the remaining gaps, in order of value

1. **Run the BUILT items on the real model and database:** `supabase/platform_setup.sql`, then upload samples, contest
   one, review it, generate a report, ask the assistant, run the analysis, and approve a proposal. Change BUILT to MET
   as each works.
2. **Notifications:** an email agent (draft, then send through a Google Apps Script web app), logged in
   `notifications_log` (5.9, 6.9, 8.4).
3. **Vector search for the knowledge base** with an embeddings model (3.4).
4. **Hosted audit engine:** move the worker, bridge and Neuro SAN server off the laptop (5.11).
5. **A live agent view in the dashboard**, so real audits can be watched as the agents work.
