# QA Platform: Technical SOP

Standard operating description of the AI QA platform: what each part is, how the parts relate, and the rules that
keep tenants isolated. Version 1.0, 2026-10-20.

---

## 1. Purpose and scope

The platform audits contact-center conversations. A transcript goes in, is stripped of personal data, is scored by an
AI model against the tenant's rubric, and the result is shown to supervisors in a web dashboard.

It is built as a **multi-tenant** system from day one: many vendors (tenants) share one codebase and one database,
and the database itself guarantees a vendor only ever sees its own rows.

In scope: ingestion, masking, scoring, dashboard, user and role management, rubric editing, export.
Out of scope for this release (see section 14): knowledge-base ingestion, rubric change-approval workflow,
performance reports, email notifications, self-serve tenant signup.

## 2. Architecture at a glance

```
                       ┌─────────────────────────── CLOUD ───────────────────────────┐
                       │                                                             │
  Browser (any user)   │   Vercel                          Supabase                  │
 ┌────────────────┐    │  ┌──────────────────────┐        ┌────────────────────────┐ │
 │ Dashboard SPA  │───────►│ FastAPI "web" app    │        │ Auth (logins, JWT)     │ │
 │ (HTML + JS)    │    │  │  - serves pages      │        │ Postgres + RLS         │ │
 │                │    │  │  - /config.js        │        │  tenants, users,       │ │
 │ supabase-js    │───────────────────────────────────────►│  transcripts, jobs,    │ │
 │ (user session) │    │  │  - /api/admin/* ─────┼───────►│  audit_scores, rubrics │ │
 └────────────────┘    │  │    (service key)     │        └───────────▲────────────┘ │
                       │  └──────────────────────┘                    │              │
                       └──────────────────────────────────────────────┼──────────────┘
                                                                      │
   ┌──────────────────────────── LOCAL MACHINE (audit engine) ────────┼──────────────┐
   │                                                                  │              │
   │  inbox/*.json ─► watcher.py ── signs in as a tenant user ────────┤ (REST, RLS)  │
   │                                                                  │              │
   │  worker.py ── claim_job() ── DATABASE_URL (role qa_worker) ──────┘ (SQL, RLS)   │
   │      │                                                                          │
   │      └─► AuditRunner ─► bridge.py (8000) ─► Chrome + Gemini Nano (CDP 9222)     │
   │                                                                                 │
   │  Neuro SAN server (8080) + Studio client (4173): agent framework and designer   │
   └─────────────────────────────────────────────────────────────────────────────────┘
```

Design rule: **multi-tenancy lives in the database, not in application code.** The web app and the worker are
different clients of the same Row-Level Security policies.

## 3. Components

| Component | Where it runs | Technology | Responsibility |
|---|---|---|---|
| Web app | Vercel | FastAPI (Python), plain HTML/JS | Serves login and dashboard pages, `/config.js`, and the admin API |
| Dashboard SPA | User's browser | JavaScript + `supabase-js` | All reads and writes under the **user's own** Supabase session |
| Admin API | Vercel (same app) | FastAPI + httpx | Creates, edits and deletes logins. The only code that holds the service-role key |
| Supabase Auth | Supabase | GoTrue | Email and password logins, JWTs |
| Database | Supabase | PostgreSQL + RLS | Source of truth; enforces tenant isolation |
| Watcher | Local | `watcher.py` (watchdog) | Takes `.json` transcripts from `inbox/`, masks PII, stores them, queues an audit |
| Worker | Local | `worker.py`, `qa_engine/job_worker.py` | Claims queued jobs, runs the audit, writes the score |
| Bridge | Local, port 8000 | `bridge.py` (FastAPI + Playwright) | OpenAI-style endpoint in front of Chrome's on-device Gemini Nano |
| Chrome (CDP) | Local, port 9222 | Chrome with Prompt and Summarizer APIs | Runs the model on the machine, so transcripts do not leave it |
| Neuro SAN server | Local, port 8080 | neuro-san | Runs the `qa_audit` agent network: an orchestrator agent delegates every rubric check to an auditor agent, and the agents use Gemini Nano through the bridge |
| Neuro SAN Studio | Local, port 4173 | nsflow | Visual designer and chat for agent networks (not needed for scoring) |

Local ports: 9222 Chrome, 8000 bridge, 8080 Neuro SAN, 4173 Studio client.

## 4. Data model and relationships

```
tenants (id, name, slug, status, branding_config, created_at)
   │ 1
   ├──< N users (id → auth.users.id, tenant_id, email, role, [agent_name])
   ├──< N rubrics (tenant_id, version, is_active, parameters jsonb)
   ├──< N transcripts (tenant_id, agent_name, channel, raw_text, uploaded_at, external_ref, ...)
   │         │ 1
   │         └──< N audit_scores (tenant_id, transcript_id, rubric_version, scores, flags,
   │                              overall_score, passed, critical_fail, scored_at)
   ├──< N jobs (tenant_id, kind='audit', payload {transcript_id}, status, attempts, error)
   └──< N audit_trail (tenant_id, actor_id, actor_email, action, detail jsonb, created_at)
```

Relationships that matter:

- **User ↔ tenant:** every login in `auth.users` has exactly one row in `public.users`, which carries `tenant_id` and
  `role`. That row is the single source of "who is this person and what can they see".
- **Transcript ↔ audit:** one transcript can have several audits (one per rubric version). `(transcript_id,
  rubric_version)` is unique, so re-auditing replaces the score instead of duplicating it.
- **Job ↔ transcript:** a job points to its transcript by `payload.transcript_id` (no foreign key). Deleting a
  transcript in the UI also deletes its jobs.
- **Rubric ↔ audit:** an audit records the rubric version it was scored with, so history stays truthful after the
  rubric changes.
- Every tenant table carries `tenant_id`. No table is shared between tenants.

Rubric `parameters` shape:

```json
{
  "pass_threshold": 80,
  "checks": [
    { "key": "greeting", "label": "Greeting", "weight": 0.10, "critical": false,
      "source": "opening", "rules": ["Agent states their name", "Agent states the recording disclosure"] }
  ]
}
```

Weights are fractions that must add up to 1. `source` is which part of the call the model reads:
`opening`, `closing`, `summary` or `full_clean`.

`audit_scores.scores` holds `summary` (text) plus one `{passed, reason}` object per check key. A human review adds a
`_review` marker `{by, at}`.

## 5. Authentication and tenant resolution

1. The user signs in on `/` with email and password. Supabase Auth returns a session (JWT).
2. The browser asks `public.users` for its own row (allowed by RLS) and gets its tenant `slug`.
3. The browser goes to `/t/{slug}/dashboard`. If the slug in the URL is not the user's own, it redirects to the
   right one. This redirect is a convenience; RLS is the real protection.
4. From then on, every query carries the JWT. Postgres resolves the tenant with `current_tenant()` and the role with
   `current_user_role()`, both reading the caller's row in `public.users`.

Path-based tenant routing (`/t/{slug}/...`) is used instead of subdomains to avoid wildcard DNS and certificates.

## 6. Roles and permissions

| Capability | admin | supervisor | team_lead | agent |
|---|:-:|:-:|:-:|:-:|
| View overview and audits (own tenant) | yes | yes | yes | own results only |
| Upload transcripts, re-audit | yes | yes | yes | no |
| Review and edit a score, edit transcript details | yes | yes | yes | no |
| Delete audits and transcripts | yes | yes | yes | no |
| Export audits, transcripts, rubric | yes | yes | yes | no |
| Edit the rubric (creates a new version) | yes | no | no | no |
| Add, delete, change role, reset password for users | yes | no | no | no |
| Rename the organization, full backup export | yes | no | no | no |

Enforcement is layered:

- **Database (authoritative):** RLS policies on every table; `save_rubric()` checks the admin role itself.
- **Admin API:** verifies the caller's session and `admin` role before using the service key.
- **UI:** hides what a role cannot do. This is usability only, never security.

## 7. The audit pipeline, step by step

1. **Input.** Either the dashboard (New audit) or a `.json` file dropped into `inbox/`.
2. **Mask PII.** Card numbers, SSNs, emails and phone numbers are replaced with `[REDACTED_...]`. The dashboard does
   this in the browser before saving; the watcher does it before saving; the worker masks again as defense in
   depth (`preprocessor.py`, `DeterministicSanitizer`).
3. **Store.** A row is written to `transcripts` under the caller's tenant. The watcher's tenant comes from the
   signed-in ingest user's row, never from the file.
4. **Queue.** A row is added to `jobs` (`kind = audit`, `payload.transcript_id`).
5. **Claim.** `worker.py` calls `public.claim_job()`, the only cross-tenant statement. It returns the oldest queued
   job and marks it taken.
6. **Scope.** The worker opens a transaction and sets `app.current_tenant` to the job's tenant. Every following
   statement runs under RLS for that tenant.
7. **Load context.** It reads the transcript text and the tenant's active rubric.
8. **Have the agents judge the checks.** `AuditRunner` summarizes the call, then sends ONE request to the `qa_audit`
   agent network on the Neuro SAN server. The message lists the check keys; the excerpt, call context and rules of each
   check travel in `sly_data`, which no model ever sees. The orchestrator agent calls the `check_auditor` agent once per
   key. Each auditor reads its task with the `load_check` code tool, judges it with Gemini Nano (through the bridge, which
   supplies tool calling), and writes its verdict with the `record_verdict` code tool. One audit of three checks takes
   about 13 model calls.
9. **Collect.** The network returns `sly_data["verdicts"]`. `VerdictParser.from_record` normalizes each verdict: only an
   explicit `true` passes. If any check has no verdict the job fails and is retried; **nothing is scored from an
   incomplete audit**. (Setting `AUDIT_BACKEND=bridge` skips Neuro SAN and asks the model directly, for debugging; each
   audit records which engine judged it in `scores._engine`.)
10. **Score.** `ScoreCalculator` (plain code, not the model) computes the result.
11. **Save.** The score is written to `audit_scores` (upsert per transcript and rubric version) and the job is marked
    done in one transaction. On error the job is requeued, up to 3 attempts, then marked failed with the error text.
12. **Display.** The dashboard refreshes every 15 seconds and shows the result.

### Scoring rules (deterministic)

- Each passed check adds `weight × 100` points.
- If any check marked **critical** fails, the call is an automatic fail with score 0, and a
  `REGULATORY_AUTO_FAIL: ...` flag is recorded.
- Otherwise the call passes when `score ≥ pass_threshold`.
- The model only proposes verdicts. It never sets the score.

## 8. Web app routes

| Route | Method | Purpose |
|---|---|---|
| `/` | GET | Login page |
| `/t/{slug}/dashboard` | GET | Dashboard shell (data loads in the browser) |
| `/config.js` | GET | Public Supabase URL and anon key |
| `/api/health` | GET | Liveness check |
| `/api/admin/users` | POST | Create a login and link it to the admin's tenant |
| `/api/admin/users/{id}` | PATCH | Change a user's role |
| `/api/admin/users/{id}/password` | POST | Set a new password |
| `/api/admin/users/{id}` | DELETE | Remove a user's access and login |

Admin API guarantees: the bearer token is verified with Supabase; the caller's row must have role `admin`; the tenant
is read from that row and never from the request; targets must belong to the same tenant; admins cannot change their
own role or delete themselves; a failed link rolls back the created login.

Dashboard views: Overview (KPIs, trend, outcomes, agents, failing checks, pipeline), Audits (filter, sort, bulk
actions, detail drawer with review and edit; for agents: "My audits" with Contest and Ask for a new audit), New audit,
Reviews (staff: contested results and re-audit requests; agents: "My requests"), Reports (performance agent), Learning
(where reviewers corrected the AI), Assistant (chat), Rubric (editor plus the research agent's proposals), Users and
roles, Knowledge base, Data and settings. Which views a person sees depends on their role.

## 9. Security controls

| Control | How it is met |
|---|---|
| Tenant isolation | RLS on every tenant table; tests in section 12 |
| No admin bypass path | The browser never holds the service key; the worker uses the restricted `qa_worker` role and scopes each transaction to one tenant; the only cross-tenant statement is `claim_job()` |
| Secrets | `.env` (git-ignored) locally; Vercel environment variables in the cloud; the service key never reaches the browser |
| PII | Masked before storage; masked again by the worker |
| Output safety | All UI text uses `textContent`; exports neutralize spreadsheet formulas |
| Auditability | Rubric versions are never overwritten; reviews are marked with reviewer and time; every job keeps its status and error; the `audit_trail` table records rubric saves (written inside the database), user changes (written by the admin API) and uploads, edits, reviews and deletions (written by the dashboard). It has no update or delete policy |
| Data at rest | Provided by Supabase managed Postgres (confirm it is enabled on your plan) |
| Least privilege | Write actions restricted by role in policies, not only in the UI |

## 10. Configuration

| Variable | Where | Meaning |
|---|---|---|
| `SUPABASE_URL` | Vercel and `.env` | Project URL |
| `SUPABASE_ANON_KEY` | Vercel and `.env` | Public key; safe in browsers because RLS is on |
| `SUPABASE_SERVICE_ROLE_KEY` | **Vercel only** | Secret key for the admin API. Mark it Sensitive. Never in `.env` of shared machines, never in the browser |
| `DATABASE_URL` | `.env` (worker) | Transaction-pooler URL for the `qa_worker` role |
| `INGEST_EMAIL`, `INGEST_PASSWORD` | `.env` (watcher) | A real tenant user the watcher signs in as |
| `BRIDGE_URL` | `.env` (optional) | Defaults to `http://127.0.0.1:8000` |
| `AUDIT_BACKEND` | `.env` (optional) | `neuro_san` (default) or `bridge` (asks the model directly, for debugging) |
| `NEURO_SAN_URL` | `.env` (optional) | Defaults to `http://127.0.0.1:8080` |
| `NEURO_SAN_NETWORK`, `NEURO_SAN_REPORT_NETWORK`, `NEURO_SAN_RESEARCH_NETWORK`, `NEURO_SAN_ASSISTANT_NETWORK` | `.env` (optional) | Network names; default `qa_audit`, `qa_report`, `qa_research`, `qa_assistant` |
| `AUDIT_EXAMPLES_PER_CHECK` | `.env` (optional) | How many reviewer-corrected examples each audit check is shown (default 2; `0` turns the learning examples off) |
| `RESEARCH_MIN_CORRECTIONS` | `.env` (optional) | Reviewer corrections needed before a check is worth analysing (default 2) |
| `BRIDGE_STRUCTURED_OUTPUT`, `BRIDGE_CONSTRAINT_TIMEOUT_SECONDS`, `BRIDGE_MODEL_TIMEOUT_SECONDS` | Bridge window (optional) | Structured-output switch and time limits of the bridge |

## 11. Deployment

- **Database:** run once in the Supabase SQL Editor: the base schema, then `supabase/admin_setup.sql` (edit and
  delete policies, organization rename, `save_rubric()`, the audit trail), then `supabase/platform_setup.sql` (review
  requests, learning data, performance reports, rubric proposals, knowledge base, chat, and the worker's permissions for
  them). Both setup files are safe to run again.
- **Web app:** `deploy-vercel.ps1` sends the `web` folder to Vercel through its REST API (no Node.js or GitHub
  needed). It needs a Vercel token and the team ID. Environment variables are set in the Vercel project and take
  effect on the next deploy.
- **Audit engine:** runs on a local machine with `start_all.bat`.

## 12. Verification (test procedures)

| Test | How | Pass means |
|---|---|---|
| Unit tests | `python -m pytest tests/qa_engine -v` | Score calculator and verdict parser behave as specified |
| Read isolation | Sign in as tenant B | Tenant A's audits and transcripts are absent |
| URL tampering | As tenant B, open `/t/<tenant-a-slug>/dashboard` | Redirected to B's own dashboard, no A data |
| Write isolation | In the browser console as tenant B: `const c = supabase.createClient(APP_CONFIG.supabaseUrl, APP_CONFIG.supabaseAnonKey); const r = await c.from('transcripts').insert({tenant_id:'<A id>', agent_name:'x', raw_text:'x'}); console.log(r.status, r.error)` | HTTP 403, code 42501 (row-level security) |
| Policies present | `select tablename, policyname, cmd from pg_policies where schemaname='public' order by 1;` | Every tenant table has policies |
| RLS switched on | `select relname, relrowsecurity from pg_class where relnamespace='public'::regnamespace and relkind='r';` | `relrowsecurity` is true for tenant tables |
| End to end | Upload a transcript, watch the worker log, see the score | Score appears within seconds |
| Role enforcement | As a supervisor, call `POST /api/admin/users` | HTTP 403 |
| Unit tests (148) | `python -m unittest tests.qa_engine.test_audit_runner tests.qa_engine.test_audit_tools tests.qa_engine.test_neuro_san_client tests.qa_engine.test_verdict_parser tests.qa_engine.test_score_calculator tests.qa_engine.test_report tests.qa_engine.test_research tests.qa_engine.test_assistant tests.qa_engine.test_learned_examples tests.qa_engine.test_job_worker tests.test_bridge_tools tests.test_bridge_endpoint tests.test_evaluate_samples` | All pass |
| Dashboard in a real browser (62 checks) | `python tests/ui/dashboard_smoke.py` (needs Chrome and `pip install playwright`) | All pass; covers every screen and what each role can do |
| Audit accuracy against the gold answers | `python evaluate_samples.py --runs 3` (engine running) | Critical fails caught 2 of 2, no false alarms, stable verdicts |
| Agent networks load | `python -m neuro_san_studio validate registries/qa_audit.hocon` (and `qa_report`, `qa_research`, `qa_assistant`, `qa_platform`) | "Validation passed" |

## 13. Technology choices and deviations from the original architecture

| Original proposal | What was built | Reason |
|---|---|---|
| Next.js + Tailwind | FastAPI-served HTML and JavaScript | No Node.js available on the working machines |
| Claude API for reasoning | On-device Gemini Nano through Chrome | Keeps transcripts on the machine; no per-call cost |
| Celery + Redis | A Postgres `jobs` table with `claim_job()` | One less moving part |
| `app.current_tenant` set per API request | `current_tenant()` function reading the JWT user (web), `app.current_tenant` per transaction (worker) | Works with Supabase's connection pooling |
| Clerk or Supabase Auth | Supabase Auth | Already hosting the database |
| S3 object storage | Not used; transcripts are rows | Not needed for text-only MVP |

## 14. The agent team, the review loop and the learning loop

All agents are Neuro SAN agent networks that use Gemini Nano through the bridge. A network is a small graph: a front-man
agent that delegates, specialist agents, and **code tools** that move data without a model ever copying it. Data for a
network travels in `sly_data`, which no model sees, so a small model only ever handles short keys and names.

| Agent network | What it does | Triggered by | Result |
|---|---|---|---|
| `qa_audit` | An orchestrator delegates every rubric check to an auditor agent | An uploaded call (job `audit`) | Verdicts, then the score (computed in code) |
| `qa_report` | A coaching agent writes advice from statistics computed in code | "Generate" on Reports (job `report`) | A row in `performance_reports` |
| `qa_research` | An advisor proposes clearer rules from reviewer corrections and policy documents | "Analyse corrections" on Learning (job `research`) | PENDING rows in `rubric_change_requests` |
| `qa_assistant` | Answers a supervisor's questions from a data pack built in code | A question in Assistant (job `chat`) | An assistant row in `chat_messages` |
| `qa_platform` | A router that hands a request to one of the four networks | Typed in the Neuro SAN Studio | Demo only (see below) |

The email/notification agent is **not built**. Of the five agents of the architecture, four exist.

**The worker** (`qa_engine/job_worker.py`) claims jobs of kind `audit` itself and hands the other kinds to a handler
(`report_handler.py`, `research_handler.py`, `chat_handler.py`). Every handler reads and writes through
`TenantDatabase.session(tenant_id)`, so tenant isolation is enforced by the database exactly as for audits.

**Review loop.** An agent opens one of their own audits and presses Contest (choosing the checks and explaining why) or
Ask for a new audit. A supervisor sees it under Reviews (the menu shows a count), opens the audit and either corrects
the score with Review & edit score (the request then closes by itself) or accepts it with a re-audit, or rejects it with
a note. A person who changes a verdict must write why. Agents can read only their own audits, create requests only for
their own audits, and cannot change anything else (enforced by Row-Level Security).

**Learning loop.** Nothing is trained. Four mechanisms use the reviewers' decisions:
1. Every correction, and every contest the supervisor rejects, is stored in `rule_feedback` (what the AI said, what the
   human decided, why). It cannot be edited or deleted from the app.
2. The Learning screen shows, per check, how often the AI was right.
3. Each audit shows its auditors up to `AUDIT_EXAMPLES_PER_CHECK` recent corrections for that check, from the same
   tenant only and masked. The audit records how many examples it used in `scores._engine.examples`.
4. The research agent reads the corrections and the knowledge-base documents and proposes new rules. **Nothing changes
   until an admin approves it**; approval saves a new rubric version through `save_rubric()`.

**Knowledge base.** An admin uploads policy documents as text (`.txt`, `.md`). They are masked, stored in
`knowledge_base_docs`, and matched to checks by shared keywords. There are no embeddings yet (Chrome's built-in AI offers
none), so matching is simple.

**Demo mode.** If a network is started with no data (typing in the Neuro SAN Studio), its code tools use a clearly
marked sample and set `sly_data["demo"] = true`. Every handler refuses anything flagged `demo`, so a demo can never
become a score, report, proposal or chat answer.

**Reliability measures.** The bridge refuses a final answer while a tool named in the agent's own instructions has not
been called; the audit asks again only for the checks that are missing (up to 3 rounds) and never scores an incomplete
audit; `evaluate_samples.py` measures accuracy against gold answers after any change.

## 15. Known gaps and next steps

- **Email and notifications:** not built (no agent, no `notifications_log` writes). A planned approach is a code tool
  that posts to a Google Apps Script web app, with recipients taken from the database and never from the model.
- **Knowledge base search** is keyword matching, not embeddings; documents are text only.
- **Audits are slower** on the agent network (about 13 on-device model calls, roughly 2.5 to 3 minutes each).
- **The learning effect is unmeasured on the real model.** Use `evaluate_samples.py` before and after turning
  `AUDIT_EXAMPLES_PER_CHECK` on, and keep the numbers.
- Creating a **new tenant** is still a SQL action (`create_tenant()`), by design for the MVP.
- The engine runs on a local machine, so scoring, reports, research and chat only happen while it is on.
- The Studio's live map shows only conversations started in the Studio, not the worker's real runs. A live agent view
  inside the dashboard is not built.

## 16. Glossary

- **Tenant:** one vendor or client organization. Everything below it is isolated.
- **RLS (Row-Level Security):** Postgres rules that filter every query by tenant.
- **JWT:** the signed token that proves who is calling.
- **Anon key / service-role key:** public key limited by RLS / secret key that bypasses RLS.
- **CDP:** Chrome DevTools Protocol, used to drive Chrome from the bridge.
- **Critical check:** a check whose failure fails the whole call.
