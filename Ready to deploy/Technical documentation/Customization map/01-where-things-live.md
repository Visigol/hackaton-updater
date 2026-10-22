# Where things live: a map of every part you may want to change

Paths are relative to the `neuro-san-studio` folder unless they start with `Technical documentation` or
`Sample transcripts mockup`. The last column says what you must do after changing it.

**Legend:** **Redeploy** = run `deploy-vercel.ps1`. **Restart worker** = close and reopen the Audit Worker window (or
run `start_all.bat`). **Restart bridge** = same for the FastAPI Bridge window. **SQL** = run in the Supabase SQL Editor.
**Nothing** = takes effect at once.

---

## 1. What the AI is asked to check (the "rules")

| What | Where | How to change | After |
|---|---|---|---|
| The checks, their rules, weights, pass mark, which part of the call each reads, which are critical | Supabase table `rubrics`, column `parameters` | **Rubric page** in the dashboard (admin). Each save is a new version | Nothing |
| The starting rubric given to a brand-new organization | The `create_tenant()` function in Supabase (a copy is in `supabase\schema.sql`) | Edit the `jsonb_build_object(...)` block, run it | SQL |
| Which tenants have which rubric | `rubrics.tenant_id` | Each organization has its own; edit while signed in to that organization | Nothing |

## 2. How the AI is asked (the "prompts")

| What | Where | How to change | After |
|---|---|---|---|
| The question sent to the AI for each check | `qa_engine\audit_runner.py`, `PROMPT_TEMPLATE` | Edit the wording. Keep the three placeholders `{label}`, `{excerpt}`, `{rules}` and the JSON reply format `{"passed": ..., "reason": ...}` | Restart worker |
| The AI's standing instruction ("You are an automated QA auditor...") | `bridge.py`, in `chat_completions`, the `sysPrompt` line | Edit the text | Restart bridge |
| Tool calling for Neuro SAN agents: how the bridge turns a list of tools into a prompt and the model's JSON back into OpenAI `tool_calls`, the retry rule (`TOOL_RETRIES`), and the wording the model is given ("HOW TO REPLY") | `bridge_tools.py` (`ToolCallAdapter`) and `bridge.py` (`tool_turn`). Tests: `tests\test_bridge_tools.py`, `tests\test_bridge_endpoint.py` | Edit the wording or rules | Restart bridge |
| Bridge time limits and the structured-output switch: `BRIDGE_STRUCTURED_OUTPUT` (`on`/`off`), `BRIDGE_CONSTRAINT_TIMEOUT_SECONDS` (default 150), `BRIDGE_MODEL_TIMEOUT_SECONDS` (default 300) | Environment variables read at the top of `bridge.py`; set them in the Bridge window before starting it, for example `set BRIDGE_STRUCTURED_OUTPUT=off` | Change the value | Restart bridge |
| Model warm-up at start-up, and the `/health` address the launcher can poll (`{"model_ready": true}` when the model is loaded) | `bridge.py`, `warm_up()` and `health()` | Edit | Restart bridge |
| Measuring how reliably Gemini Nano handles tool calling (go/no-go) | `check_tool_calling.py` (run: `python check_tool_calling.py 20`) | Change the tools or the task text at the top of the class | Nothing |
| Randomness of the AI (temperature, topK) | `bridge.py`, in `chat_completions`, the `attempts` list. The bridge prints its mode when it starts answering: `deterministic` or `default-sampling` | Change `topK` or the temperature the worker sends | Restart bridge |
| The summary (style, length) | `qa_engine\bridge_client.py`, `summarize()` payload (`"type": "key-points"`, `"length": "short"`). Executed in `bridge.py`, function `summarize_text` | Change the values | Restart worker |
| The model used | Chrome's on-device Gemini Nano, reached through `bridge.py` (needs Chrome started with the flags in `start_all.bat`). The client class is `qa_engine\bridge_client.py`: the place to plug in a different model | Replace the calls in `BridgeClient` | Restart worker |

## 3. How a call is cut up and cleaned

| What | Where | How to change | After |
|---|---|---|---|
| How much counts as "opening" (6 lines) and "closing" (5 lines) | `preprocessor.py`, `slice_transcript()` (`lines[:6]`, `lines[-5:]`) | Change the numbers | Restart worker **and** watcher |
| What personal data is masked | `preprocessor.py`, `mask_pii()` (card, SSN, email, US phone) | Add or edit patterns | Restart worker and watcher |
| The same masking in the browser | `web\dashboard_js_core.py`, function `maskPii` | **Must match `mask_pii()`**; edit both | Redeploy |
| Dropped calls: the note added to the prompt when a transcript ends with a marker such as `[call disconnected]`, `[line dropped]` or `[customer hung up]` | `qa_engine\audit_runner.py`, `DISCONNECT_MARKER` and `_call_context()`; tests in `tests\qa_engine\test_audit_runner.py` | Add marker wordings to the pattern, or edit the note text | Restart worker |
| Names of the parts a check can read | Rubric page "Reads" list: `web\dashboard_js_admin.py`, constant `SOURCES`. The worker reads them in `qa_engine\audit_runner.py` (`opening`, `closing`, `summary`, anything else = whole transcript) | Add a new part in both places | Redeploy and restart worker |

## 4. How the answer becomes a score

| What | Where | How to change | After |
|---|---|---|---|
| Turning the AI's answer into pass or fail | `qa_engine\verdict_parser.py` | Edit parsing; tests in `tests\qa_engine\test_verdict_parser.py` | Restart worker |
| Weights, critical-fail rule, pass mark maths | `qa_engine\score_calculator.py` | Edit; tests in `tests\qa_engine\test_score_calculator.py` | Restart worker |
| The same maths in the browser (used by "Review and edit score") | `web\dashboard_js_core.py`, function `computeResult` | **Must match `ScoreCalculator`**; edit both | Redeploy |

## 5. How transcripts get in and jobs get run

| What | Where | How to change | After |
|---|---|---|---|
| The watched folders (`inbox`, `processed`, `failed`) | `watcher.py` (`INBOX`, `PROCESSED`, `FAILED`) | Change the paths | Restart watcher |
| The file format accepted from the folder (`id`, `agent_id`, `raw_transcript`, `call_duration_seconds`) | `qa_engine\ingest_handler.py`, method `ingest()` | Edit the field names | Restart watcher |
| The same fields on the website upload | `web\dashboard_js_admin.py`, function `renderNew` (JSON branch) | Edit | Redeploy |
| How jobs are claimed, retried (3 attempts) and paused | `qa_engine\job_worker.py` (`MAX_ATTEMPTS`, sleep times); entry point `worker.py` | Edit the constants | Restart worker |
| Secrets and connection strings | `.env` (read by `qa_engine\settings.py`): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `INGEST_EMAIL`, `INGEST_PASSWORD`, `DATABASE_URL`, `BRIDGE_URL` | Edit the file | Restart watcher and worker |
| What starts and stops, and in what order | `start_all.bat`, `stop_all.bat` (ports 9222, 8000, 8080, 4173; Chrome path and flags) | Edit | Nothing |
| Test call generator | `generate_stress_call.py` | Edit the transcript text | Nothing |

## 6. The website

| What | Where | How to change | After |
|---|---|---|---|
| Routes, the admin user API, the list of roles (`ROLES`) | `web\app.py` | Edit | Redeploy |
| Login page and the Supabase library version | `web\pages.py` (`LOGIN_PAGE`, `SUPABASE_JS`) | Edit | Redeploy |
| Colors, fonts, layout, dark mode, page title ("QA Platform") | `web\dashboard_page.py` (`STYLE`, `BODY`) and `web\pages.py` (`LOGIN_STYLE`) | Edit the CSS variables at the top | Redeploy |
| Words on screen (menu names, "Agent", "Transcript", "Audits", status names) | `web\dashboard_js_core.py` (`VIEWS`, `STATUS`, table headers) and `web\dashboard_js_admin.py` | Search for the word and replace | Redeploy |
| Overview charts and tiles | `web\dashboard_js_core.py`, function `renderOverview` | Edit | Redeploy |
| Audits table, detail panel, review and edit | `web\dashboard_js_core.py` (`renderAudits`, `paintDrawer`, `paintReview`) | Edit | Redeploy |
| Rubric editor, users screen, exports, activity log | `web\dashboard_js_admin.py` | Edit | Redeploy |
| Role descriptions on the Users screen | `web\dashboard_js_admin.py`, `ROLE_INFO` | Edit | Redeploy |
| Python packages for the website | `web\requirements.txt` | Edit | Redeploy |
| How the site is deployed (project name `qa-platform`, framework) | `deploy-vercel.ps1` (in the folder above `neuro-san-studio`) | Edit parameters | Nothing |
| Vercel secrets (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) | Vercel project, Settings, Environment Variables | Edit there | Redeploy |

## 7. The database

| What | Where | After |
|---|---|---|
| Base tables, helper functions and policies (the version used for new projects) | `supabase\schema.sql` | SQL |
| First organization and first admin | `supabase\seed.sql` | SQL |
| Editing, deleting, rubric saving, audit trail table `audit_trail` | `supabase\admin_setup.sql` (safe to re-run) | SQL |
| Cleaning up the old `activity_log` clash | `supabase\fix_activity_log_clash.sql` (run once) | SQL |
| Roles allowed (`admin`, `supervisor`, `team_lead`, `agent`) | Three places must agree: the `users.role` check in the database, `ROLES` in `web\app.py`, `ROLE_INFO` in `web\dashboard_js_admin.py` | SQL and redeploy |
| Who can do what | Row-Level Security policies in Supabase (view with `select * from pg_policies where schemaname='public';`) | SQL |

## 8. The agent framework (Neuro SAN)

| What | Where | Note |
|---|---|---|
| **The audit agent network** (the one that judges every check): an orchestrator `qa_audit` that calls an auditor agent `check_auditor` once per check; each auditor reads its task with `load_check` and records its verdict with `record_verdict` | `registries\qa_audit.hocon` (enabled in `registries\manifest.hocon`) | Edit the agents' instructions, the parameters, or add agents | Restart the Neuro-San window |
| The two code tools of that network, and the **demo sample** the agents use when started from the Studio without data (`DEMO_CHECKS`, the Anna call). Demo verdicts carry `demo: true` and the audit worker refuses them | `coded_tools\qa_audit\load_check.py`, `coded_tools\qa_audit\record_verdict.py`; tests in `tests\qa_engine\test_audit_tools.py` | Edit | Restart the Neuro-San window |
| How the worker calls the network and gets the verdicts back (`sly_data`) | `qa_engine\neuro_san_client.py` and `AuditRunner._verdicts_from_agents` in `qa_engine\audit_runner.py`; tests in `tests\qa_engine\test_neuro_san_client.py`, `test_audit_runner.py` | Edit | Restart worker |
| Which engine judges the checks, and where the Neuro SAN server is | `.env` or the Worker window: `AUDIT_BACKEND` (`neuro_san` default, or `bridge` to skip Neuro SAN for debugging), `NEURO_SAN_URL` (default `http://127.0.0.1:8080`), `NEURO_SAN_NETWORK` (default `qa_audit`). Read in `worker.py` | Change the value | Restart worker |
| The older example network (orchestrator plus two auditors). **Not used by the audit.** Its sub-agents have no `parameters`, so they receive an empty message | `registries\qa_network.hocon` | Can be removed from `manifest.hocon` | Restart the Neuro-San window |
| The model settings the networks use | `llm_config` inside each `.hocon` file (Gemini Nano through the bridge on port 8000) | Edit | Restart the Neuro-San window |
| Start order, ports and the wait for the model | `start_all.bat` (the worker starts only when `http://127.0.0.1:8000/health` says `model_ready` and the Neuro-San server answers) | Edit | Nothing |

### The other agent networks (reports, research, assistant, router)

| What | Where | After |
|---|---|---|
| Performance report network, its two tools, and the statistics it describes | `registries\qa_report.hocon`, `coded_tools\qa_report\`, `qa_engine\performance_stats.py` (the numbers), `qa_engine\report_handler.py` (the job) | Restart the Neuro-San window; restart the worker for handler changes |
| Rubric research network, its tools, and how corrections and policy documents become findings | `registries\qa_research.hocon`, `coded_tools\qa_research\`, `qa_engine\findings_builder.py`, `qa_engine\research_handler.py` | Same |
| Chat assistant network, its lookup tool, and the data pack it can read | `registries\qa_assistant.hocon`, `coded_tools\qa_assistant\lookup_data.py`, `qa_engine\assistant_pack.py`, `qa_engine\chat_handler.py` | Same |
| The router that shows all the networks together in the Studio | `registries\qa_platform.hocon` (it calls the others as `/qa_audit` and so on) | Restart the Neuro-San window |
| Which networks are served | `registries\manifest.hocon` | Restart the Neuro-San window |
| Which job kinds the worker handles, and the handlers' wiring | `qa_engine\job_worker.py`, `qa_engine\job_handler.py`, `qa_engine\handler_factory.py`, `worker.py` | Restart worker |
| How a handler reads and writes under a tenant's scope | `qa_engine\tenant_database.py` | Restart worker |
| Reviewer-corrected examples shown to the auditors, and how many | `qa_engine\learned_examples.py`; the count is `AUDIT_EXAMPLES_PER_CHECK` | Restart worker |
| The number of corrections that makes a check worth analysing | `RESEARCH_MIN_CORRECTIONS` | Restart worker |
| The demo samples the agents use when started from the Studio | `DEMO_...` constants in the code tools under `coded_tools\qa_report\`, `qa_research\`, `qa_assistant\`, `qa_audit\` | Restart the Neuro-San window |
| The database tables, policies and worker permissions for these features | `supabase\platform_setup.sql` (safe to re-run) | SQL |
| The screens: Reviews and contests, Reports, Learning, Assistant, Knowledge base, Rubric proposals | `web\dashboard_js_workflow.py` (menu and role rules are in `web\dashboard_js_core.py`, `VIEWS`) | Redeploy |
| Accuracy measurement: the rubric, gold answers and the four samples | `evaluation\` and `evaluate_samples.py` | Nothing |
| The dashboard browser test and its fake Supabase | `tests\ui\dashboard_smoke.py`, `tests\ui\fake_supabase.py` | Nothing |

## 9. Tests, samples and documents

| What | Where |
|---|---|
| Automated tests | `tests\qa_engine\` (run: `python -m unittest tests.qa_engine.test_verdict_parser tests.qa_engine.test_score_calculator`, or `python -m pytest tests/qa_engine -v` if pytest is installed) |
| Mock calls and the answer key | `Sample transcripts mockup\` |
| This documentation | `Technical documentation\` |

## 10. Things that must be changed together

| If you change... | ...also change |
|---|---|
| Masking patterns | `preprocessor.py` **and** `maskPii` in `web\dashboard_js_core.py`, and the table in the sample answer key |
| Scoring rules | `qa_engine\score_calculator.py` **and** `computeResult` in `web\dashboard_js_core.py`, and their tests |
| Rubric part names ("opening", "closing", ...) | `SOURCES` in the Rubric editor **and** `qa_engine\audit_runner.py` |
| Roles | The database role check, `ROLES` in `web\app.py`, `ROLE_INFO` in the dashboard, and the policies that mention role names |
| A table or column name | The SQL files, the queries in `qa_engine\job_worker.py` and `qa_engine\ingest_handler.py`, and the `db.from(...)` calls in the dashboard |
