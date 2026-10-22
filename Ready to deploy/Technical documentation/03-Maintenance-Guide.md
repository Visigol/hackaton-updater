# QA Platform: Maintenance Guide

What an administrator needs to do to keep the platform healthy, secure and recoverable.

---

## 1. Routine schedule

| How often | Task | Section |
|---|---|---|
| Every working day | Check the Pipeline card on the Overview and the Worker window | 2 |
| Weekly | Review failed jobs; review the user list; download a full backup | 3, 5, 7 |
| Monthly | Run the isolation check; review rubric versions; check Supabase usage and limits | 6, 8, 10 |
| Weekly | Answer the review queue; skim the activity log | 8b |
| Monthly | Run `evaluate_samples.py --runs 3`; analyse corrections and decide on proposals; review the knowledge base | 8b |
| Quarterly | Rotate secrets; update dependencies; test a restore | 4, 9, 7 |
| On every change to the database | Re-run the isolation check | 6 |

## 2. Daily health check (2 minutes)

1. Open the dashboard Overview and look at **Pipeline**. It should be empty or only recent items.
2. Look at the **Audit Worker** window on the engine machine. A healthy worker prints `Queue empty; waiting for new
   jobs` or `Job ... done`.
3. Open `<site url>/api/health`. It should answer `{"status":"ok"}`.
4. If any of these are wrong, go to section 11.

SQL view of the same:

```sql
select status, count(*) from public.jobs group by status;
select count(*) as waiting_over_10_min from public.jobs
where status = 'queued' and created_at < now() - interval '10 minutes';  -- drop the created_at line if the column is absent
```

## 3. Handling failed or stuck audits

A job is retried automatically up to 3 times, then marked `failed` with the error text (visible in the dashboard).

Common causes: Chrome closed, bridge not running, the model returned something unusable, a long transcript timed out.

1. Fix the cause (start the engine with `start_all.bat`).
2. In the dashboard, select the failed rows in Audits and choose **Re-audit**.

To requeue every failed job at once (SQL Editor):

```sql
update public.jobs set status = 'queued', attempts = 0, error = null where status = 'failed';
```

To clear a job that should never run (for example a deleted transcript):

```sql
delete from public.jobs where payload->>'transcript_id' not in (select id::text from public.transcripts);
```

## 4. Secrets and key rotation

| Secret | Where it lives | Rotate when | How |
|---|---|---|---|
| Vercel token | Your notes only (used by `deploy-vercel.ps1`) | After every use | Delete it at vercel.com/account/tokens; create a new one next time |
| Supabase anon key | Vercel and local `.env` | Suspected leak, or yearly | Supabase, Project Settings, API; update both places; redeploy |
| Supabase service-role key | **Vercel only** | Suspected leak, staff change, quarterly | Rotate in Supabase; update `SUPABASE_SERVICE_ROLE_KEY`; redeploy |
| Database password / `DATABASE_URL` | Local `.env` | Quarterly | Change the `qa_worker` password in Supabase; update `.env`; restart the worker |
| Ingest user password | Local `.env` | Quarterly, or when someone leaves | Reset it from Users and roles; update `.env`; restart the watcher |

Rules: never paste a key into chat, email or a ticket. If one is exposed, treat it as compromised and rotate it
immediately. The service-role key must never be in `.env` on a shared machine, in browser code, or in the repository.

## 5. User administration (all from the website)

- **Joiner:** Users and roles, Add a user. Choose the lowest role that works (`supervisor` for reviewers, `agent` for
  agents). Share the temporary password securely.
- **Role change:** drop-down in the user table. Takes effect at the next page load.
- **Leaver:** delete the user the same day. Access ends immediately because the tenant link is removed. Also reset the
  ingest user's password if they knew it.
- **Forgotten password:** key icon, set a new one.
- **Last admin:** keep at least two admins. An admin cannot change or delete their own account, so the second admin is
  also your recovery path.
- **Review:** once a month, scan the user list for people who should no longer have access, and for unnecessary
  admins.

**Review the activity log** (Data and settings, Activity log) weekly. Look for unexpected user creations, role
changes to `admin`, mass deletions or rubric saves you do not recognize. The log is the compliance trail; do not delete
its rows in SQL. Keep it at least as long as your retention policy for audits.

## 6. Isolation check (run after any database change)

This proves one tenant cannot see or write another's data. Needs two tenants with a user each.

1. Sign in as tenant B in a private window. The audits list must show none of tenant A's data.
2. Change the address to `/t/<tenant-a-slug>/dashboard`. You must be sent back to B's own dashboard.
3. In the browser console, still as B:

   ```js
   const c = supabase.createClient(APP_CONFIG.supabaseUrl, APP_CONFIG.supabaseAnonKey);
   const r = await c.from('transcripts').insert({tenant_id: '<TENANT A ID>', agent_name: 'x', raw_text: 'x'});
   console.log(r.status, r.error);
   ```

   Expected: `403` and an error mentioning row-level security. If it succeeds, **stop and fix before anyone uses the
   system**, then run `delete from public.transcripts where agent_name = 'x';`.
4. Confirm policies and RLS are on:

   ```sql
   select tablename, policyname, cmd from pg_policies where schemaname = 'public' order by tablename, cmd;
   select relname, relrowsecurity from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r';
   ```

   Every tenant table must show `relrowsecurity = true` and have policies.

Never add a policy such as `using (true)`, and never use the service-role key for anything a user does.

## 7. Backup and restore

- **Weekly:** Data and settings, then **Full backup (JSON)**. Store it somewhere access-controlled. It contains
  transcripts (already masked) and user emails.
- **Supabase's own backups:** check which are included in your plan, and how long they are kept. Daily backups are
  usually on paid plans only.
- **Rubric:** download the rubric JSON after each change you consider important.
- **Restore test (quarterly):** restore into a *separate* test project, run the schema and `admin_setup.sql`, and
  check you can sign in. An untested backup is not a backup.
- **If the Vercel site is lost:** redeploy with `deploy-vercel.ps1`; the data is not on Vercel.

## 8. Rubric governance

- Every save creates a new version; old versions are kept, and every audit records the version it used.
- Before saving, check the weights total 100% and mark as **Critical** only the rules where one failure makes the
  call non-compliant.
- After a change, re-audit a few known calls to see the effect before relying on the new rubric.
- Roll back from Version history with **Restore**.

## 8b. Reviews, learning and proposals

- **Review queue (weekly or more often):** Reviews should not collect old pending requests. Answer every contest, even
  with a short note: agents who get no answer stop trusting the system.
- **Watch for abuse:** one pending request of each kind per audit is allowed. If one agent contests everything, talk to
  them; the Activity log shows who asked for what.
- **Corrections need reasons:** the dashboard forces a reason when a verdict is changed. If you export `rule_feedback`
  and find empty reasons, a different tool wrote them.
- **Analysis and proposals (monthly, or after about 10 new corrections):** an admin presses "Analyse corrections". Read
  each proposal against the corrections it cites before approving. Approve one check at a time and run
  `python evaluate_samples.py --runs 3` afterwards. If accuracy drops, restore the previous rubric version from Version
  history.
- **Learning examples:** `AUDIT_EXAMPLES_PER_CHECK` (default 2) controls how many corrected examples each check sees. To
  test whether they help, run `evaluate_samples.py` with it at 0 and at 2 and compare. Set it to 0 if results get worse.
- **Knowledge base:** review the documents quarterly. An outdated policy document makes the research agent propose
  outdated rules. Delete what is no longer true.
- **Chat history:** `chat_messages` holds each person's conversation. Decide a retention period and purge old rows, for
  example `delete from public.chat_messages where created_at < now() - interval '90 days';`.
- **Reports:** `performance_reports` grows by one row per generated report; keep or purge according to your policy.
- **Privacy:** reports and chat answers are built from masked transcripts and results, but they do name agents. Treat
  them as personnel data.

## 9. Updates and dependencies

- **Web app:** `web\requirements.txt` lists `fastapi` and `httpx`. Test locally before deploying a newer version.
- **Supabase JS:** pinned in `pages.py` (`SUPABASE_JS`). Upgrade deliberately; test login, upload and export afterwards.
- **Audit engine:** `pip install -r requirements.txt` inside `venv`. Re-run `python -m pytest tests/qa_engine -v`.
- **Chrome:** the on-device AI features change between versions. After a Chrome update, run one test audit.
- Keep a short changelog of what you changed and when.

## 10. Capacity and cost watch

- **Supabase:** check database size, auth users and bandwidth monthly against your plan limits.
- **Vercel:** check function usage. Dashboard data loads in the browser, so usage is small.
- **Dashboard size:** the list loads the latest 500 transcripts. If a tenant grows far beyond that, export old data and
  delete it, or ask for pagination to be added.
- **Retention:** decide how long transcripts are kept (compliance may set this). To purge old data:

  ```sql
  -- Review first, then run. Deletes transcripts and their scores older than 12 months.
  delete from public.audit_scores where transcript_id in
    (select id from public.transcripts where uploaded_at < now() - interval '12 months');
  delete from public.transcripts where uploaded_at < now() - interval '12 months';
  ```

## 11. Troubleshooting reference

| Symptom | Likely cause | Fix |
|---|---|---|
| Login page: "supabaseUrl is required" | Environment variables not applied | Set `SUPABASE_URL` and `SUPABASE_ANON_KEY`, redeploy, open `/config.js` |
| Cannot sign in | Wrong password, or user not confirmed | Reset the password; users made by the admin API are pre-confirmed |
| "Not linked to an organization" | Missing `public.users` row | Add the user from the website, or insert the row in SQL |
| Dashboard empty but data exists | Date range too narrow, or wrong tenant | Choose All time; check the organization name |
| Upload fails with RLS error | Role is `agent`, or the `tenant_id` default / insert policy is missing | Check role; run `admin_setup.sql`; check the column default |
| Delete / edit / rename says setup needed | `admin_setup.sql` not run | Run it |
| Saving a rubric fails | `save_rubric()` missing, or the caller is not an admin | Run `admin_setup.sql`; check the role |
| Add user fails: missing key | `SUPABASE_SERVICE_ROLE_KEY` not set | Add on Vercel; redeploy |
| Add user fails: "already registered" | A login with that email exists, possibly in another organization | Use a different email or delete the old login |
| Add user fails linking to the organization | The `users` table has a required column the form does not send | Read the message; add the column's value or change its default |
| Audits stay Queued | Worker, bridge or Chrome not running | `start_all.bat`; read the Worker window |
| Worker: "Database unreachable" | Wrong `DATABASE_URL`, password changed, network | Check `.env`; it retries every 15 seconds |
| Worker: "no active rubric" | Tenant has no active rubric | Open Rubric and save one, or run `create_tenant` for new tenants |
| Bridge: "Could not connect to Chrome CDP on port 9222" | Chrome not started with debugging | Use `start_all.bat` (it starts Chrome first) |
| Model API "not available" | Gemini Nano not downloaded or flags missing | Open the dedicated Chrome profile; confirm the on-device model is installed |
| Scores look wrong | Rubric rules vague, or model slip | Tighten rules; use Review and edit score; re-audit |
| Site shows old version | Browser cache | Ctrl+F5 |
| 401/403 from the user API | Session expired, or not an admin | Sign in again; check the role |

### Agent features

| Symptom | Likely cause | Fix |
|---|---|---|
| A screen says it needs the database setup | `supabase/platform_setup.sql` not run, or run before `admin_setup.sql` | Run `admin_setup.sql`, then `platform_setup.sql` |
| Reports, research or chat jobs stay queued | The worker was started before the update, so it does not claim those kinds | Restart the Audit Worker; it should log `polling for jobs of kind: audit, report, research, chat` |
| Job fails: "check constraint" on `kind` | The `jobs` table limits the kind column | `platform_setup.sql` widens it; run it again |
| Job fails: "permission denied" for a table | The `qa_worker` role lacks access to a new table | Run `platform_setup.sql` (its last block grants it) |
| Job fails: "did not record a report / any proposal / usable answer" | The model could not finish the steps | Retry; check the Bridge window for `rejected` lines; run `python check_tool_calling.py` |
| "returned DEMO ..." in a job error | The request reached the network without its data | A worker bug or an old worker; restart the worker from the current code |
| Chat answers are empty or odd | Question too long or outside the data | Ask a shorter question about agents, checks or critical fails |
| A contest cannot be created | The audit does not belong to that agent, or a pending one exists | Check `users.agent_name` and the existing requests |

## 12. Incident response

1. **Suspected data exposure between tenants:** take the site offline (remove the Vercel production domain or the
   Supabase anon key), run the isolation check, inspect `pg_policies`, fix, re-test, then restore access. Record what
   happened.
2. **Leaked key:** rotate it (section 4), redeploy, review recent users and audits for unexpected changes.
3. **Wrong data deleted:** restore from the latest full backup or Supabase backup into a test project first, then copy
   back only what is needed.
4. **Engine machine down:** nothing is lost. Jobs wait in the queue and run when the engine is back.

## 13. Checklists

**Before a deploy**
- [ ] Local smoke test passes
- [ ] New environment variables added on Vercel
- [ ] A fresh Vercel token is ready
- [ ] After deploy: `/api/health`, sign in, open an audit

**After a database change**
- [ ] Isolation check (section 6)
- [ ] One upload and one audit end to end
- [ ] Fresh full backup

**When someone leaves**
- [ ] User deleted the same day
- [ ] Ingest password reset if they knew it
- [ ] Any keys they could see rotated
