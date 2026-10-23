# Adapting the platform to something other than call-center QA

The platform is a general "score a piece of text against a tenant's rules" machine. This is the order to change things
when you want it to review something else: sales calls, support emails, chat logs, written complaints, loan
applications. Each step points to the detailed map in `01-where-things-live.md`.

---

## Step 1: Decide what is being reviewed

Write down, in one page:

- **The unit.** What is one item? (a call, an email thread, a document)
- **The checks.** What questions do you ask of every item, and how important is each? These become the rubric.
- **The critical rules.** Which failures should fail the whole item regardless of the rest?
- **The pass mark.**
- **Who sees what.** Which roles exist? (The built-in roles are admin, supervisor, team_lead, agent.)

## Step 2: Rewrite the rubric (no code needed)

Open **Rubric** as an admin. For each check set the label, weight, whether it is critical, what part it reads, and write
the rules. Weights must total 100%. Save it as a new version.

Good rules are specific, observable and say what counts. See the "Rule-writing tips" at the end.

For new organizations, replace the starting rubric in the `create_tenant()` SQL function (map section 1).

## Step 3: Choose which part of the item each check reads

Right now there are three views: **opening** (first 6 lines), **closing** (last 5 lines), **summary** (AI-written) and
**whole transcript**. For other material you may want different slices, for example "subject line" for emails or
"first paragraph" for letters.

- Change the sizes in `preprocessor.py`, `slice_transcript()`.
- To add a new named part, add it to `SOURCES` in `web\dashboard_js_admin.py` and handle it in
  `qa_engine\audit_runner.py`.

Rule of thumb: let any check that could be broken anywhere read the **whole transcript**. Short views are cheaper, but a
check can only judge what it reads.

## Step 4: Adjust the wording of the prompt

In `qa_engine\audit_runner.py` the template says "transcript excerpt". For other material change that word and any
"call" language in the standing instruction in `bridge.py` (`sysPrompt`). Keep the JSON reply format.

If your items are not conversations, also change the summary style in `qa_engine\bridge_client.py`.

## Step 5: Update what is masked

Different material holds different sensitive data (patient numbers, national IDs, addresses, account numbers). Edit the
patterns in `preprocessor.py`, **and** the matching `maskPii` in `web\dashboard_js_core.py`. Test them with a few real
examples. This step matters for compliance; do not skip it.

## Step 6: Rename things on screen

Search the dashboard files for the words to replace. The common ones:

| Currently | Where |
|---|---|
| "QA Platform" | `web\dashboard_page.py`, `web\pages.py` |
| "Audits", "New audit", "Transcript", "Agent" | `web\dashboard_js_core.py` (`VIEWS`, table headers, drawer), `web\dashboard_js_admin.py` |
| Result names (Passed, Failed, Critical fail) | `web\dashboard_js_core.py`, `STATUS` |
| Role descriptions | `web\dashboard_js_admin.py`, `ROLE_INFO` |

The internal names (database tables `transcripts`, `audit_scores`, the `agent_name` column) can stay as they are. Users
never see them, and renaming them touches many files. Only rename them if you are prepared to follow the table in
section 10 of the map.

## Step 7: Change how items arrive

- Folder feed: the field names are in `qa_engine\ingest_handler.py`. Change `raw_transcript` and `agent_id` to what your
  source produces.
- Website upload: same fields in `web\dashboard_js_admin.py`, function `renderNew`.
- A new source (an email inbox, an API): write a small script that does what `ingest()` does (mask, store a transcript
  row, add a `jobs` row), signed in as a tenant user.

## Step 8: Replace the AI model if needed

All model calls pass through `qa_engine\bridge_client.py` (`summarize` and `complete`). To use a different model,
change those two methods to call your model and keep their return types. The rest of the platform does not care which
model answers.

## Step 9: Update tests and samples

1. Replace the mock calls in `Sample transcripts mockup\` with realistic items for the new use case, including tricky
   ones: a polite violation, a hostile but compliant case, and a messy boundary case.
2. Write the answer key before you run the AI.
3. Run each sample three times and record the results in a scorecard.
4. Update `tests\qa_engine\` if you changed the scoring or parsing rules.

## Step 10: Re-deploy and re-document

1. Run any SQL changes in Supabase.
2. Restart the Audit Worker and the Bridge.
3. Redeploy the website.
4. Update `Technical documentation\` (the SOP, user guide and maintenance guide) with the new terms and the new
   requirements checklist.

---

## Rule-writing tips (they decide how accurate the AI is)

1. **Make each rule one observable thing.** "Agent is polite" is vague; "Agent greets the customer in the first two turns"
   is checkable.
2. **Define the words that matter.** In the first run, "verification" was undefined and the AI accepted a phone number as
   verification. Say what counts and what does not.
3. **Accept different wordings.** "MUST explicitly ask if the customer needs further assistance" failed a call that said
   "Does that cover everything you needed?" Say "in any wording with that meaning".
4. **Say what to do in odd cases.** For example, if the customer drops the call, that is not the agent ending it.
5. **Let a critical check read everything.** A rule that can only be seen in the middle of a call must not read just the
   opening.
6. **Keep rules few.** Small on-device models do better with three clear rules than ten overlapping ones.
7. **Test with a trap.** For every rule, include a sample that breaks it politely, and a sample that follows it while
   looking bad.
8. **Expect some variation.** Small models can answer the same question differently on different runs. Treat scores near
   the pass mark, or calls where repeated runs disagree, as needing human review.
