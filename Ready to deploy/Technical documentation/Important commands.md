# Important commands

Cheat sheet for the demo and for day-to-day work: deploy, Supabase, the engine, packaging.
**Placeholders are in `<ANGLE BRACKETS>`. Never paste real tokens/passwords into chat, screenshots or documents.**

Folders used below (adjust if yours differ):

- Project: `C:\Users\Utilizador\Documents\hackaton\neuro-san-studio`
- Parent (holds `deploy-vercel.ps1`): `C:\Users\Utilizador\Documents\hackaton`
- Live site: `https://qa-platform-ivory.vercel.app`

---

## 1. Deploy the web app to Vercel

Create a token at <https://vercel.com/account/tokens> (revoke it after the demo). The team id is `team_…`
(Vercel → Settings → General).

```powershell
cd C:\Users\Utilizador\Documents\hackaton
powershell -ExecutionPolicy Bypass -File .\deploy-vercel.ps1 -Token "<VERCEL_TOKEN>" -TeamId "<team_xxxxx>" -WebDir ".\neuro-san-studio\web"
```

(Run it from the folder that contains `deploy-vercel.ps1`; `-WebDir` points at the `web` folder.)

Check it is alive:

```powershell
curl.exe https://qa-platform-ivory.vercel.app/api/health
```

Vercel environment variables the site needs (set in Vercel → Project → Settings → Environment Variables):
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (service key lives **only** in Vercel).
After changing a variable, deploy again.

---

## 2. Supabase: running SQL

Supabase dashboard → **SQL Editor** → New query → paste → **Run**.

Setup files, in this order (all in `neuro-san-studio\supabase\`):

| Order | File | Purpose |
|---|---|---|
| 1 | `schema.sql` | Tables, RLS policies, helper functions |
| 2 | `admin_setup.sql` | Admin / user management support, `audit_trail` |
| 3 | `platform_setup.sql` | Reviews, reports, learning, chat, jobs kinds, worker grants |
| – | `fix_activity_log_clash.sql` | Only if you hit the `activity_log` column error |
| – | `seed.sql` | Demo data (optional) |

Everything is written to be safe to re-run.

### Look around (read-only, good for the demo)

```sql
-- Tables and whether row security is on
select tablename, rowsecurity from pg_tables where schemaname = 'public' order by 1;

-- Policies per table
select tablename, policyname, cmd from pg_policies where schemaname = 'public' order by 1, 2;

-- How many rows per tenant
select tenant_id, count(*) from transcripts group by 1;

-- Queue health
select kind, status, count(*) from jobs group by 1, 2 order by 1, 2;

-- Latest jobs and errors
select id, kind, status, attempts, left(coalesce(error, ''), 80) as error, created_at
from jobs order by created_at desc limit 15;
```

> If a column name differs in your database, run `select * from jobs limit 1;` first to see the real names.

### Fix a stuck queue

```sql
-- Put failed jobs back in the queue so the engine retries them
update jobs set status = 'queued', attempts = 0 where status = 'failed';

-- A job stuck "in progress" because an engine was switched off (see the status names first with the queue query above)
update jobs set status = 'queued' where status not in ('queued', 'done', 'failed');
```

### Users and roles

```sql
select email, role, agent_name from users order by role, email;

-- Link an agent login to the name that appears in transcripts
update users set agent_name = '<Agent Name>' where email = '<agent@company.com>';

-- Change a role (admin | supervisor | team_lead | agent)
update users set role = 'supervisor' where email = '<person@company.com>';
```

(Prefer the **Users** screen of the app for creating users: it also creates the login.)

### Change or delete data

```sql
-- Delete ONE test transcript (look first, then delete)
select id, agent_name, created_at from transcripts order by created_at desc limit 10;
delete from transcripts where id = '<TRANSCRIPT_UUID>';

-- Add a column safely
alter table transcripts add column if not exists note text;

-- Remove it again
alter table transcripts drop column if exists note;
```

Always `select` with the same `where` before any `update` / `delete`.

### Rotate passwords (do this before sharing the package)

```sql
-- Database password of the restricted worker role (then put the new one in the engine's .env)
alter role qa_worker with password '<NEW_STRONG_PASSWORD>';
```

Ingest user password: app → **Users** → key icon next to the ingest user. Then send managers a new `.env` and have
them run **Update-secrets.cmd**.

### Backups / exports

- Dashboard → **Database → Backups** (daily backups on paid plans).
- Table → **Export to CSV** in the Table Editor.
- In the app: the **Exports** screen.

---

## 3. The local engine (Windows command line)

Developer machine (your folder):

```powershell
cd C:\Users\Utilizador\Documents\hackaton\neuro-san-studio
.\start_all.bat        # start Chrome+Nano, bridge, Neuro SAN, studio, watcher, worker
.\stop_all.bat         # stop them
```

Who is listening on the ports (9222 Chrome, 8000 bridge, 8080 Neuro SAN, 4173 Studio):

```powershell
netstat -ano | findstr "9222 8000 8080 4173"
taskkill /F /PID <PID>
```

Health checks:

```powershell
curl.exe http://127.0.0.1:8000/health                 # model_ready should be true
curl.exe http://127.0.0.1:8080/api/v1/list            # the agent networks served
```

Ask a network directly (shows Neuro SAN working, no database involved):

```powershell
curl.exe -X POST http://127.0.0.1:8080/api/v1/qa_assistant/streaming_chat -H "Content-Type: application/json" -d "{\"user_message\":{\"text\":\"Hello\"}}"
```

Follow the logs live (manager installation):

```powershell
Get-Content C:\QAEngine\data\logs\worker.log -Wait -Tail 20
Get-Content C:\QAEngine\data\logs\bridge.log -Wait -Tail 20
```

Live logs for a demo (installed engine): double-click **QA Engine – Show logs** (`C:\QAEngine\launcher\Show-Logs.cmd`). It opens one window per log and tiles them; add `-All` (`powershell -ExecutionPolicy Bypass -File C:\QAEngine\launcher\show-logs.ps1 -All`) to include the watcher and Studio. It only reads the logs, so the engine is not touched. Start the engine first.

Tests and checks:

```powershell
cd C:\Users\Utilizador\Documents\hackaton\neuro-san-studio
python -m unittest discover -s tests -p "test_*.py"          # engine + bridge unit tests
python check_tool_calling.py                                  # can the model drive Neuro SAN tools?
python evaluate_samples.py                                    # accuracy against the gold answers
python -m neuro_san_studio validate registries\qa_audit.hocon # validate an agent network
```

Drop a transcript into the hot folder (watcher masks PII and queues it):

```powershell
Copy-Item "..\Sample transcripts mockup\*.json" .\inbox\
```

---

## 4. Download Gemini Nano (browser console)

Do this in the **dedicated Chrome window** that the engine opens (profile `C:\ChromeNanoSession`), not in your normal
Chrome. Open any page of the engine (for example `http://127.0.0.1:8000/`), press **F12 → Console**, paste, Enter.

```js
(async () => {
  if (!('LanguageModel' in self)) { console.log('LanguageModel API missing: start Chrome through the engine (flags) and use Chrome 138+'); return; }
  console.log('Availability before:', await LanguageModel.availability());
  const session = await LanguageModel.create({
    monitor(m) { m.addEventListener('downloadprogress', e => console.log('Downloading Gemini Nano: ' + Math.round(e.loaded * 100) + '%')); }
  });
  console.log('Test answer:', await session.prompt('Reply with the single word OK.'));
  session.destroy();
  console.log('Availability after:', await LanguageModel.availability(), '-> Nano is ready');
})();
```

- `downloadable` / `downloading` → the model is fetched (about 2 GB); keep Chrome open until it prints `Nano is ready`.
- If the console refuses to start the download, click once inside the page and run the snippet again (Chrome wants
  a user gesture).
- Optional check in `chrome://on-device-internals` (model status), and `chrome://components` → *Optimization Guide On
  Device Model* → *Check for update*.
- The first answer after a restart takes 1–3 minutes (model load). `curl http://127.0.0.1:8000/health` shows `model_ready`.

---

## 5. Package and install for the other managers

Build (creates/updates `C:\Users\Utilizador\Documents\hackaton\Ready to deploy`):

```powershell
cd C:\Users\Utilizador\Documents\hackaton\neuro-san-studio
powershell -ExecutionPolicy Bypass -File .\packaging\build_package.ps1 -Version 1.0.1
```

What the managers get: copy the whole **Ready to deploy** folder to their laptop and double-click **Install.cmd**. It
asks for the `.env` file (send it privately: never inside the zip), then installs to `C:\QAEngine`. A re-install keeps
the saved settings. The step-by-step guide is `INSTALLATION-GUIDE.md` in that folder (copy: `Installation guide.md`).

Daily use on a manager's laptop: desktop shortcuts **QA Engine – Start / Status / Stop**.
New `.env` (rotated password): `C:\QAEngine\launcher\Update-secrets.cmd`.

Quick unattended test of an install (uses a throw-away folder and a fake `.env`):

```powershell
powershell -ExecutionPolicy Bypass -File ".\Ready to deploy\install.ps1" -InstallDir "$env:TEMP\qa-test" -EnvFile "<fake.env>" -SkipDeps -NoShortcuts
```

---

## 5b. Switch the AI: Gemini Nano or cloud Gemini

Edit the engine's `.env` (see `packaging\env.template`):

```text
AI_PROVIDER=gemini                 # or nano
GOOGLE_API_KEY=<the Gemini key>    # only for gemini
GEMINI_MODEL=gemini-2.5-flash
```

On an installed engine, apply it and restart:

```powershell
C:\QAEngine\launcher\Update-secrets.cmd        # choose the edited .env
C:\QAEngine\launcher\Stop.cmd
C:\QAEngine\launcher\Start.cmd                  # the window says (AI: gemini) and Chrome does not open
```

In the project folder (development), rewrite the agent networks by hand and check them:

```powershell
cd C:\Users\Utilizador\Documents\hackaton\neuro-san-studio
python switch_llm.py gemini
python -m neuro_san_studio validate registries\qa_audit.hocon
python evaluate_samples.py
```

Full explanation: `Agent building guide.md`, section 6. Step-by-step for the managers: `Installation guide.md`.

---

## 6. Where the secrets are

| Secret | Where it lives | If it changes |
|---|---|---|
| Supabase URL / anon key | `.env`, Vercel env vars | Update both, redeploy |
| Service role key | **Vercel only** | Redeploy |
| Ingest e-mail + password | `.env` (engine) and the Supabase user | Change in Users screen, new `.env` |
| `qa_worker` DB password | `.env` (`DATABASE_URL`), Postgres role | `alter role …`, new `.env` |
| Vercel token | Your head / vercel.com/account/tokens | Revoke after use |

`.env` is git-ignored, skipped by `deploy-vercel.ps1`, and excluded from the package by `build_package.ps1`
(the build stops if it finds anything secret-looking).

---

## 7. Five-minute show-off sequence

1. `curl.exe https://qa-platform-ivory.vercel.app/api/health` – site is up.
2. Supabase SQL Editor: *tables and RLS* query, then the *queue health* query.
3. `netstat -ano | findstr "9222 8000 8080"` and `curl.exe http://127.0.0.1:8000/health` – engine is up, model ready.
4. `curl.exe http://127.0.0.1:8080/api/v1/list` – the Neuro SAN agent networks.
5. `Copy-Item` a sample transcript into `inbox\`, watch `Get-Content …\worker.log -Wait`, then refresh the dashboard.
6. `deploy-vercel.ps1` – ship a change live (do this last; it takes about a minute).
