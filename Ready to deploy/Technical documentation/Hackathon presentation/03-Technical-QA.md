# Technical questions and answers

Click a question to open the answer. Use the search box on the left to find any word across all documents. Each answer is written to be said in 30 seconds; the second sentence is the detail if they push.

## Neuro SAN and the agents

### What is Neuro SAN, and why did you use it?

Neuro SAN is an open-source multi-agent framework from Cognizant's AI Lab. A team of agents (an *agent network*) is described in a text file (HOCON), and the server runs it: each agent is a role with instructions, and agents can call tools or other agents. It was the required framework for the project, and it fits well: the audit really is a team of specialists, not one prompt.

### What is an agent network, a front man, a sub-agent and a coded tool?

An **agent network** is one file with several agents. The **front man** is the first agent: it receives the request and delegates. A **sub-agent** is another AI agent that the front man calls like a tool, with one narrow job. A **coded tool** is not AI: a small Python class that does one deterministic thing (read data, save a result). In our audit team: `qa_audit` is the front man, `check_auditor` the sub-agent, and `load_check` and `record_verdict` the coded tools.

### How do the agents communicate?

By tool calling. The coordinator's model is given the sub-agent as a tool and answers "call check_auditor with check_key=compliance". Neuro SAN runs the sub-agent as its own conversation and returns the result to the coordinator as a tool result. Every message carries an `origin` chain (who called whom), which is what our AGENTS log prints.

### What is `sly_data`, and why do you use it?

It is a private channel that travels with the request but is never shown to any model. We put the transcript excerpts and rules in it, and the verdicts come back through it. Small models copy long text badly, so the models only pass short keys like `compliance`, and the coded tools fetch the real data. It also keeps call content out of prompts.

### Do the networks talk to each other?

Not in production. The worker reads the job kind (`audit`, `report`, `research`, `chat`) and calls the matching network directly. They are connected through the database: audits feed reports, corrections feed the researcher, an approved rule change changes the next audit. Only the demo router, `qa_platform`, calls the other networks, using Neuro SAN's external-network tools.

### Why five networks and not one big agent?

A small on-device model is much more reliable with one narrow job per team. It also lets each team have its own limits (`max_steps`, `max_execution_seconds`), tools and data, and lets us improve one without touching the others.

### How does the worker call Neuro SAN?

With an HTTP POST to `/api/v1/<network>/streaming_chat`, sending the request text and the `sly_data`. It reads the streamed messages; the last one carries the final answer and the `sly_data` with the verdicts. For the AGENTS log it also asks for the full message stream (the "maximal" chat filter).

### Did you modify Neuro SAN?

No. We did not fork or patch it. Everything we built is configuration (the HOCON files), coded tools, and code beside it (the bridge, the worker, the handlers). That is why updating the framework or switching models does not break our agents.

### How did being open source help you in practice?

Four ways: we could read how the framework calls a model and plug in any OpenAI-compatible endpoint (our bridge); we could write our own coded tools; we learned its rules from the source and docs (a tool needs at least one argument, the front man must be an LLM agent, sly_data needs an explicit allow policy); and we could validate our networks with its own `validate` command.

### What is Studio?

The web page (port 4173) that shows an agent network and lets you chat with it. Audits from the website do not appear there, because they run on the server directly, but typing a request in Studio shows the agents talking live (with demo data).

### What are `max_steps` and `max_execution_seconds`?

Safety limits in each network so an agent cannot loop forever. If a run exceeds them, Neuro SAN stops it and the worker records a failed attempt.

### Which Neuro SAN features are you not using yet?

Agent **skills**, **MCP** servers, **middleware** (PII detection, call limits), **LLM fallbacks**, the observability plugins (Phoenix, Langfuse), and the toolbox tools (Gmail, Jira, PDF readers). They are in the roadmap: skills for coaching styles, MCP and Gmail for alerts, fallbacks and tracing once the cloud model arrives.

## Gemini Nano and the bridge

### What is Gemini Nano?

A small model that Chrome can run on the user's device, exposed to web pages through the Prompt API (`window.LanguageModel`). Nothing leaves the machine for the AI step.

### Why do you need a bridge?

Neuro SAN talks to models in the OpenAI chat format over HTTP. Nano is not a server: it is a JavaScript API inside a Chrome page. The bridge is the translator: a small FastAPI server that accepts the OpenAI-style request and runs it in Chrome.

### How does the bridge talk to Chrome?

Chrome is started with a debugging port (9222). The bridge connects to it with Playwright over the Chrome DevTools Protocol and runs a small JavaScript function in a page served from `127.0.0.1:8000` (the Prompt API needs a real origin). Values go in as arguments, never pasted into the script.

### Nano cannot call tools. How do your agents call tools?

The bridge adds tool calling. It describes the tools to the model in plain text, asks for a JSON reply (`tool_calls` or an `answer`), constrains the reply with a JSON schema, validates it (known tool, required arguments, no repeated call) and retries with the reason if it is invalid. Then it converts it to a normal OpenAI tool call. Nano still decides which tool and which arguments; Neuro SAN actually runs the tools.

### Isn't that faking tool calls?

No. The decision is the model's, and the tools are really run by Neuro SAN. The bridge only translates the format. The one sentence the bridge can write itself is the agent's closing line ("Recorded.") when the work is done and the model returned an empty reply; it never invents a verdict, a score or a tool call.

### How do you make the answers repeatable?

Temperature 0 and top-K 1 when the browser allows it, structured output (the reply must match a JSON schema) with a timeout and a plain fallback, and the score computed in code. The bridge logs which sampling mode it got.

### Why is an audit slow?

The on-device model answers one request at a time and each turn takes 10 to 30 seconds; an audit is many turns (a coordinator turn plus about four per check). About 3 to 5 minutes today. A queue in the bridge makes parallel requests wait their turn so none of them times out.

### What about the first call after a restart?

The model loads on first use, which can take from about 20 seconds to a few minutes. The bridge warms it up when it starts and reports `model_ready` on `/health`, and the launcher waits for it before starting the worker.

### What happens if Chrome's AI API changes?

That is a real risk: the Prompt API is still evolving. The bridge isolates it in one file, and the design lets us switch to a cloud model with a setting, so Chrome is not a permanent dependency.

### Is Nano accurate enough?

Not alone, and we do not pretend it is. Alone it made serious mistakes on our hard sample calls. That is why we added code-side checks, the critical-fail guard, a human review queue and a learning loop. We measured it on a small set of mock calls with answer keys; building a larger set is the next step.

## Architecture, data and security

### Why Vercel plus Supabase plus a local engine?

Each part does what it is best at: Vercel serves the web app with no server to manage, Supabase gives login, Postgres and row-level security, and the local engine keeps the AI on the company's hardware. It also matched our constraints: no Node or GitHub for Vercel (we deploy through its API), no database we could install.

### How does the queue work?

The website inserts a row in `jobs` with a kind and the transcript id. The worker calls a database function (`claim_job`) to take the next job, runs it, saves the result and marks it done. Failures are retried up to three times, then marked failed with the error. If no engine is running, jobs simply wait.

### What if two engines are running?

They share the same queue, and each takes jobs through `claim_job`. That function comes from the original database setup; we rely on it handing a job to one engine at a time, and I would confirm it uses row locking before relying on it with many engines.

### How do you isolate customers (tenants)?

Three layers. At login a hook puts `tenant_id` and `user_role` in the token; every table has row-level security that compares `tenant_id` with the token; and the worker connects as a restricted database role and sets the tenant for each job inside its transaction. We verified it with two tenants. The service key is only in Vercel.

### Where are the secrets?

In a `.env` file that is never in the package. On the engine laptops the installer stores it encrypted for the Windows user (DPAPI). The Vercel service key lives only in Vercel's environment settings. Passwords are rotated at the source (the database role and the ingest user).

### What data leaves the laptop?

Only masked transcript text and the results, sent to Supabase. In Nano mode the AI step stays on the laptop. In cloud mode the masked text would go to Google, which needs data-protection approval first.

### What exactly is masked?

Card numbers, US-style SSNs, e-mail addresses and phone numbers, before upload. Known gaps: CVV, PIN, expiry date, addresses, international phone numbers and IBANs. We list them openly and would close them before any cloud use.

### How are roles enforced?

Four roles (admin, supervisor, team lead, agent). Enforcement is in the database policies, and the page only reflects it. Agents see only their own audits, linked by their agent name; staff see their company's data.

### Is there an audit trail?

Yes: rubric saves, user changes, uploads, re-audits and reviews are written to an `audit_trail` table that cannot be edited from the app.

### How would this scale?

Each engine processes one job at a time, so capacity grows by adding engines on the same queue, or by moving to a cloud model that runs checks in parallel. Postgres is not the limit at this size.

## Accuracy, scoring and learning

### Who calculates the score?

Code. The agents only give a pass or fail with a reason per check. A Python class applies the weights, the pass mark and the critical-fail rule, so the result is explainable and repeatable.

### How do you prevent invented critical fails?

A critical fail sets the score to 0, so it must be backed up. The guard requires the reason to quote a line the agent really said, and that line must share a meaningful word with the check's rules. If not, the verdict is marked unverified, the call gets a `NEEDS_REVIEW` flag instead of a 0, and it cannot pass. A person decides.

### How does the "verification before details" check work?

Code finds the first line where the agent states an amount or account detail the customer had not said, and the first line where the agent asks for a date of birth, PIN or security answer. If the details come first, or there is no verification, the identity check fails with the two lines quoted. It is a fact counted by code, so it does not depend on the model.

### What is your accuracy?

I would not quote a percentage: we have four hard mock calls with answer keys, plus the real behaviour we iterated on. On those, the guard rails fixed the worst errors (a false pass and two false alarms). The honest next step is a set of 20 to 30 labelled calls and a script that scores every version against it.

### How do reviewers correct a result?

On any audit they open Review and edit score, change the verdicts and must write a new reason if they flip one. Agents can contest a result or ask for a new audit. Audits the AI itself flagged appear in Reviews under "Flagged by the AI".

### How does the system learn?

Every changed verdict is saved with what the AI said and what the human decided. Two things use it: the next audits show the auditors up to two corrected examples per check, and the research agent turns repeated corrections (and matching policy text) into proposed rule changes. A person approves each proposal, and it becomes a new rubric version; the old ones are kept.

### Can each client have different rules?

Yes. The rubric is a JSON document per tenant with versions. The worker loads the active version of the tenant that owns the call, and every score records which version produced it.

### Why are the model's reasons sometimes wrong?

Small models can pick a verdict and then write a reason that does not match. We counter it with the quote guard, computed facts for the checks that can be counted, and human review. A planned improvement is to make the model write the reason before the verdict.

### How did you test without the real model?

Unit tests with scripted stand-ins: about 143 for the engine, 35 for the bridge and its tool adapter, and 9 for the sample evaluation. The website has 73 checks in a real browser against a fake database. We also ran the real Neuro SAN server with a scripted model to verify the message stream. We cannot automate the real Nano, so that part is checked by hand.

## Operations

### How do the managers run it?

They copy one folder and run the installer, then use four desktop shortcuts: Start, Stop, Status and Show logs. Start runs the supervisor, which restarts anything that crashes, keeps the PC awake, and starts the services in the right order.

### How do updates and rollbacks work?

The new version installs beside the old one and keeps the saved settings. Start always uses the version named in one small file, so a rollback is changing that number and restarting.

### How do you see what is happening?

The Status screen, one log file per service, and the live agents window (Show logs). Tracing with Phoenix or Langfuse is in the roadmap.

### What if the engine crashes during an audit?

The attempt fails and the job is retried, up to three times. A known gap: a job left "in progress" by a stopped engine stays that way until someone requeues it. A stale-job reaper (automatic reclaim) is planned.

### Why PowerShell and cmd scripts?

Because the target is locked-down Windows laptops with no admin rights. The scripts need nothing installed beyond Python and Chrome, and the installer can install Python through winget if it is allowed.

## Cloud, roadmap and honesty

### How do you switch to cloud Gemini?

One setting in the engine's secrets file (`AI_PROVIDER=gemini` plus the credential). The launcher rewrites the model block of every network and skips Chrome and the bridge. Our call-summary client has a Gemini version too.

### What is blocking the cloud key?

The company's Google Cloud project blocks plain API keys. The options we proposed are a service account with the Vertex AI role, or a sign-in with the company Google account; the framework supports the Google credential route natively. We are waiting for the approval and the project details.

### What changes with a cloud model?

Checks run in parallel (seconds instead of minutes), a five-check rubric becomes practical, and we can add a second-opinion agent for critical fails. The data-protection approval and the masking gaps become the main requirements.

### Why not use a cloud model from the start?

There was no key or approval, and the project required keeping call data private. Because Neuro SAN lets us change the model with one block, starting local did not close any door.

### What did you build, and what did you reuse?

Reused: Neuro SAN, Supabase, Vercel, Chrome's Prompt API, Playwright, FastAPI. Built: the five agent networks and their seven coded tools, the bridge and its tool-calling adapter, the worker and the job handlers, the code-side checks and the guard, the web application, the installer and launcher, the documentation and the tests.

### What are the weaknesses?

Say them first: Nano alone is not reliable, so we rely on guard rails and humans; an audit takes minutes; accuracy is measured on a small set; the PII masking has gaps; there is no automatic reclaim of stuck jobs yet; the cloud access is not approved yet.

### What would you do with another month?

Build the larger test set and a regression runner, add the stale-job reaper and failure back-off, close the masking gaps, switch to the cloud model and add a verifier agent for critical fails, and add tracing and the e-mail alert agent.

### Isn't this just a prompt?

No. It is five agent teams with delegation and coded tools, a private data channel, a queue and workers, tenant-safe storage, a review and learning loop, and code that makes the final decisions. The prompts are the smallest part.

### Why not call the Gemini API directly from the web app?

Calls would then be sent to a third party from the browser, with the keys exposed, and with no private channel for the data. The engine design keeps the call text on our side, scores in code, and the model swappable.

## Hard-to-answer questions (short, honest lines)

### "Can I trust a 0 or a 100 from this?"

Today: treat a clear pass or a computed fail as strong, and anything flagged Needs review as a question for a person. That is the point of the flag.

### "What happens to my data if I stop using it?"

It lives in your Supabase project. The engine keeps nothing except the logs on the laptop, and the exports screen downloads everything (audits, transcripts, rubric, users, backup).

### "Who can change the rules?"

Only admins save a rubric, and each save is a new version. The research agent can only propose; it never edits a rubric.

### "What if the model is wrong and nobody notices?"

That is why the score has reasons with quotes, why critical fails need evidence, why unproven ones go to a human, and why agents can contest. We would also measure the review rate to see where the model struggles.
