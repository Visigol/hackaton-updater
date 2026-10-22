# QA Platform: User Guide

How to start everything, how to use the web dashboard, and how to work with the backend when you need to.

---

## 1. What you are running

Two halves that talk through the same Supabase database:

- **The website** (on Vercel): where people sign in, upload transcripts and read results. Always on. Nothing to start.
- **The audit engine** (on your computer): watches for new transcripts, asks the AI to score them, and saves the
  scores. **Scores only appear while this half is running.**

## 2. One-time setup (done once per environment)

Skip this if the platform is already set up.

### 2.1 Supabase

1. Create the project and note the **Project URL**, the **anon (publishable) key** and the **service-role key**
   (Project Settings, then API).
2. In the SQL Editor, run the base schema, then `neuro-san-studio\supabase\admin_setup.sql`, then
   `neuro-san-studio\supabase\platform_setup.sql` (review requests, learning data, reports, proposals, knowledge base,
   chat). All of them can be re-run safely.
3. Create the first organization and its first admin. In Authentication, then Users, choose Add user (tick Auto
   Confirm User). Then in the SQL Editor:

   ```sql
   select public.create_tenant('Acme BPO', 'acme-bpo');

   insert into public.users (id, tenant_id, email, role)
   select u.id, t.id, u.email, 'admin'
   from auth.users u join public.tenants t on t.slug = 'acme-bpo'
   where u.email = 'admin@yourcompany.com';
   ```

   After this first admin exists, **everything else is done from the website**.

### 2.2 Vercel environment variables

In the project, go to Settings, then Environment Variables. Add for Production:

| Name | Value |
|---|---|
| `SUPABASE_URL` | `https://<ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | the anon / publishable key |
| `SUPABASE_SERVICE_ROLE_KEY` | the secret / service-role key. Mark it **Sensitive** |

Then deploy again (variables only apply to new deployments).

### 2.3 The local `.env` file (audit engine)

In `neuro-san-studio\.env`:

```
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<anon key>
INGEST_EMAIL=<email of a real user in the tenant>
INGEST_PASSWORD=<their password>
DATABASE_URL=<transaction pooler URL of the qa_worker role>
```

Never commit `.env`, and never put the service-role key in it.

### 2.4 Local software

- Python virtual environment named `venv` inside `neuro-san-studio`, with `pip install -r requirements.txt`.
- Google Chrome with the on-device AI features available (Gemini Nano downloaded). `start_all.bat` opens a dedicated
  Chrome profile with the right flags.

## 3. Deploying the website

From the folder that contains `deploy-vercel.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-vercel.ps1 -Token "<VERCEL_TOKEN>" -TeamId "<team_id>" -WebDir ".\neuro-san-studio\web"
```

- The token comes from vercel.com/account/tokens. Create it, use it, delete it.
- The Team ID is under the team's Settings, then General.
- The script lists the files it uploads (it should include `app.py`, `pages.py`, `dashboard_page.py`,
  `dashboard_js_core.py`, `dashboard_js_admin.py`, `requirements.txt`) and prints the URL.
- Check it worked: open `<url>/api/health`. It should return `{"status":"ok"}`.

## 4. Starting the audit engine

Double-click `neuro-san-studio\start_all.bat`. It cleans old processes and opens these windows:

| Window | What it is | Port |
|---|---|---|
| 1. Chrome CDP | Chrome with the on-device AI | 9222 |
| 2. FastAPI Bridge | Lets the code talk to Chrome's AI | 8000 |
| 3. QA File Watcher | Picks up `.json` files from `inbox\` | |
| 3b. QA Audit Worker | Claims queued jobs and scores them | |
| 4. Neuro-San Backend | Agent framework server | 8080 |
| 5. NSFlow Studio Client | Visual agent designer (opens in the browser) | 4173 |
| 6. Manual Work and Test Terminal | A ready terminal for commands | |

**Is it healthy?** In the Worker window you should see `Worker started; polling for audit jobs` and then
`Queue empty; waiting for new jobs`. Leave Chrome open and do not close the windows.

To stop everything, run `stop_all.bat`.

## 5. Using the website

Open the Vercel URL and sign in. You land on your organization's dashboard at `/t/<your-slug>/dashboard`.
The menu on the left changes with your role. The sun/moon button switches light and dark mode.

### 5.1 Overview

- **Date range** (7 / 30 / 90 days, all time) filters every chart and number on the page.
- **Tiles:** audits scored, average score, pass rate, critical fails, agents audited.
- **Score trend:** each dot is an audit. Hover for details, click to open it. The dashed line is the pass mark.
- **Outcomes:** share of passed, failed and critical audits.
- **Average score by agent** and **Where audits fail** (pass rate per check, worst first). Use the second one to see
  what to coach.
- **Pipeline:** transcripts that are waiting, running or failed, with the error text.

### 5.2 Audits

- Search by agent, filter by result, sort, and page through results.
- Click a row (or the eye icon) to open the **detail panel**: score ring, AI summary, every check with its pass or fail
  and the reason, flags, and the transcript.
- **Review and edit score:** switch any check between Pass and Fail and edit the reason. The score is recalculated
  with the same rules as the worker and the audit is marked "Reviewed by you". Use this to correct the AI.
- **Edit details:** fix the agent name, channel or text. Choose **Save and re-audit** to score it again.
- **Re-audit** queues a fresh score. **Delete** removes the transcript, its score and its job (asks first).
- Tick several rows to re-audit or delete in bulk.

### 5.3 New audit

- Drop one or many `.txt` or `.json` files, and/or paste a transcript. A `.json` file may hold
  `{"agent_id": "...", "raw_transcript": "..."}` or a list of them.
- Card numbers, SSNs, emails and phone numbers are masked in your browser before saving.
- Each transcript is saved and queued. A green line confirms it, a red line says why it failed.

### 5.4 Rubric (admins)

- Set the **pass mark**, and add, edit, reorder or remove **checks**. Each check has a key, label, weight, what part of
  the call it reads, its rules (one per line) and an optional **Critical** flag (failing it fails the whole call).
- Weights must total 100%. The page tells you if they do not.
- **Save as new version** creates a new active version. Old audits keep the version they were scored with.
- **Version history** lets you restore any older version (this also creates a new version).

### 5.5 Users and roles (admins)

- **Add a user:** email, role, optional agent name, and a temporary password (use the generator). The login works
  immediately. Copy the credentials shown and share them securely; they are shown once.
- **Change a role** with the drop-down in the table.
- **Reset a password** with the key icon. **Delete a user** with the bin icon: they lose access at once.
- You cannot change your own role or delete yourself. Ask another admin.

### 5.6 Data and settings

- **Organization:** admins can rename the display name.
- **Activity log (admins):** the latest 50 actions in your organization: who did what and when (rubric saved, user
  created or deleted, role changed, audits uploaded, edited, reviewed or deleted). Entries cannot be edited or deleted.
- **Exports:** audits (CSV, with a pass or fail column per check), transcripts (CSV), rubric (JSON), users (CSV) and a
  full backup (JSON). Open CSVs in Excel; text that looks like a formula is neutralized.

### 5.7 What an agent sees

People with the role **agent** get a smaller menu: Overview, My audits, My requests, Reports and Data and settings. They see
only their own calls and results. Opening one of their audits shows the score, the reason for every check, the
transcript, and two buttons:

- **Contest this result:** choose the checks you disagree with and explain why (at least 10 characters). The checks that
  failed are ticked for you.
- **Ask for a new audit:** explain why the call should be scored again.

Only one pending request of each kind is allowed per audit. Agents cannot change, delete or upload anything. Their
requests and the answers appear under **My requests**.

### 5.8 Reviews (admins, supervisors, team leads)

**Reviews** lists the requests from agents. The menu shows a red number while some are waiting. Open the audit (the eye
icon) and the request appears at the top of the panel. You can:

- **Review & edit score:** correct the checks. If you change a verdict you must write why (the old reason would
  contradict it). Saving closes the contest automatically.
- **Accept and re-audit:** the call is audited again and the agent is told.
- **Reject:** write a short note the agent will see. Rejecting a contest confirms the AI, which is also saved as learning
  data.

### 5.9 Reports

Choose an agent and a period (7, 30 or 90 days) and press **Generate**. The performance agent writes a short coaching
report from numbers calculated by the system: audits, average, pass rate, trend, and how each check went, with strengths,
things to improve and next steps. It takes a few minutes. Agents can read their own reports.

### 5.10 Learning (admins, supervisors, team leads)

Shows, per check, how often reviewers agreed with the AI, and the latest corrections side by side (what the AI said and
what the reviewer said). An admin can press **Analyse corrections and propose rule changes**, which asks the research
agent for clearer rules. Nothing is trained; see the SOP, section 14, for how the AI uses the corrections.

### 5.11 Rubric proposals (admins)

On the **Rubric** screen, below the editor, **Proposed changes** lists what the research agent suggests: the current
rules next to the proposed ones, why, and how many corrections it is based on. **Approve** saves the change as a new
rubric version (old audits keep their version); **Reject** leaves the rubric alone. The AI never changes the rubric by itself.

### 5.12 Assistant (admins, supervisors, team leads)

Ask questions about your results in plain language, for example "How is Anna doing?", "Which check fails the most?" or
"Were there any critical fails recently?". The answer takes about a minute. It uses only the last 30 days of your own
organization's audits, cannot see anything else, and cannot change anything. **Clear** deletes your conversation.

### 5.13 Knowledge base (admins)

Drop policy documents (`.txt` or `.md`, up to 200 KB each) such as your recording-disclosure or identity-verification
rules. Card numbers, emails and phone numbers are masked before saving. The research agent reads them when it proposes
better rules.

## 6. Working with the backend directly

### 6.1 Dropping a transcript file

Create a `.json` file in `neuro-san-studio\inbox\`:

```json
{
  "id": "call-0001",
  "agent_id": "AGT-0042",
  "call_duration_seconds": 312,
  "raw_transcript": "Agent: Thank you for calling...\nCustomer: Hi..."
}
```

The watcher masks it, stores it under the ingest user's tenant and queues the audit. The file moves to `processed\`,
or to `failed\` if something is wrong (the watcher window says why).

### 6.2 Generating a realistic test call

```powershell
cd neuro-san-studio
venv\Scripts\activate
python generate_stress_call.py
```

This writes a ten-minute call (with fake card and SSN numbers to prove masking) into `inbox\`.

### 6.3 Running the automated tests

```powershell
cd neuro-san-studio
venv\Scripts\activate
python -m pytest tests/qa_engine -v
```

### 6.4 Useful database checks (Supabase, SQL Editor)

```sql
-- Who is in which organization?
select u.email, u.role, t.slug from public.users u join public.tenants t on t.id = u.tenant_id;

-- How is the queue doing?
select status, count(*) from public.jobs group by status;

-- Latest scores
select tr.agent_name, a.overall_score, a.passed, a.critical_fail, a.scored_at
from public.audit_scores a join public.transcripts tr on tr.id = a.transcript_id
order by a.scored_at desc limit 10;
```

### 6.5 Adding a brand-new organization (platform owner)

```sql
select public.create_tenant('Other BPO', 'other-bpo');
```

Create its first admin in Authentication, then Users, and link them as in section 2.1. The new admin then manages
their own people from the website.

### 6.6 Measuring the audit's accuracy

```powershell
cd neuro-san-studio
venv\Scripts\activate
python evaluate_samples.py --runs 3
```

It audits the four mock calls in `evaluation\samples` three times each through the real engine and compares the verdicts
with the gold answers in `evaluation\gold.json`. It reports the share of correct verdicts, how many critical fails were
caught (it must be all of them), false alarms, and whether the verdicts were the same on every run. Run it after any
change to the rubric, the prompts or the agents, and keep the numbers. Use `--only Anna` for one sample.

### 6.7 Showing the agents working in the Neuro SAN Studio

Open the Studio (http://127.0.0.1:4173), select **qa_platform**, and type a request such as `Audit a call`,
`Write the coaching report for agent Anna`, `Improve the compliance rules` or `How is Anna doing?`. The router hands it to the
right team and you can watch the agents on the map and in the internal chat. Started this way the agents work on a
built-in **demo** sample (marked DEMO DATA), and the system refuses to store anything produced from it. You can also select
`qa_audit`, `qa_report`, `qa_research` or `qa_assistant` directly. The Studio shows only conversations started in the
Studio, not the audits the worker runs.

## 7. Quick troubleshooting

| What you see | Likely cause | What to do |
|---|---|---|
| Login says "supabaseUrl is required" | Vercel variables missing or not yet deployed | Set them, then deploy again; check `<url>/config.js` |
| Login works but "not linked to an organization" | No row in `public.users` | Link the user (section 2.1) or add them from Users and roles |
| Upload says "violates row-level security" | `tenant_id` default or insert policy missing, or role is `agent` | Check the user's role; run `admin_setup.sql` |
| Delete or edit says the database needs setup | `admin_setup.sql` not run | Run it in the SQL Editor |
| Audit stays "Queued" | Worker or bridge not running, or Chrome closed | Run `start_all.bat`; read the Worker window |
| Audit shows "Error" | The model call failed 3 times | Open the audit; read the error; check the Bridge window and Chrome |
| Add user fails with "server is missing ... SERVICE_ROLE_KEY" | Variable not set on Vercel | Add it and deploy again |
| Blank dashboard after deploy | Old cached page | Hard refresh (Ctrl+F5) |
| A new screen says it needs the database setup | `platform_setup.sql` not run | Run it in the SQL Editor |
| A report or analysis stays "being written" | The Neuro-San Backend, Bridge or Chrome is not running, or the worker is busy | Start the engine; read the Audit Worker window |
| "Nothing to learn from yet" after Analyse | Fewer than 2 reviewer corrections on any check | Review and correct some audits first |
| The assistant never answers | Same as above, or the job failed three times (the chat then shows the reason) | Check the Audit Worker and Neuro-San Backend windows |
| An agent cannot see their audits | Their `users` row has no `agent_name` matching the name on the calls | Set `agent_name` for that user |

More in the Maintenance Guide.
