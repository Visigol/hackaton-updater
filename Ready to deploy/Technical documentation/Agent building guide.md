# Agent building guide

For whoever helps build the **research** and **performance** agents. It explains what an agent is in this project,
gives a template, and points to working examples. Everything refers to real files in `neuro-san-studio\`.

---

## 1. What is an "agent" here?

An agent is **one role with one job**, written in plain English, that can use **tools** (and other agents) to get
it done. In Neuro SAN an agent is a block in a `.hocon` text file. There is no program to write for the agent itself.

An agent has five parts:

| Part | Field in the file | Meaning |
|---|---|---|
| Name | `"name"` | How others call it. The first agent's name must equal the file name |
| Purpose | `"function": {"description"}` | One sentence telling OTHER agents when to use it (what it does) |
| Inputs | `"function": {"parameters"}` | What it needs when called (for example `check_key`) |
| Instructions | `"instructions"` | Step-by-step text telling the agent HOW to do its job |
| Tools | `"tools": [...]` | Which other agents or Python tools it may call |

A **network** is a set of agents in one file, with a single entry point.

- **Front man (coordinator):** the first agent. It receives the request and delegates. It is always an AI agent.
- **Sub-agent (specialist):** an AI agent with one narrow job, called by another agent as if it were a tool.
- **Coded tool:** not an AI. A small Python class that does exactly one deterministic thing (read data, save a result,
  calculate). Declared with `"class": "file.ClassName"`.

> Rule of thumb: **AI decides and writes; Python reads, saves and calculates.** Numbers and scores come from Python.

Two rules we learned the hard way:
- `function.description` says WHAT the agent does (for other agents). `instructions` says HOW. Do not mix them.
- Every tool needs at least one argument, or Neuro SAN silently ignores it.

---

## 2. How data moves: `sly_data`

Agents talk to models in text, and small models copy long text badly. So big data (transcripts, statistics,
rubric rules) never goes through a prompt. It travels in **`sly_data`**, a private data channel next to the
conversation:

1. The worker puts the data in `sly_data` when it calls the network.
2. A coded tool reads it (`sly_data.get("checks")`) and hands the agent only what it needs.
3. A coded tool writes results back (`sly_data["verdicts"]`).
4. The front man lists what may go back to the worker: `"allow": {"to_upstream": {"sly_data": ["verdicts"]}}`.

The AI only passes short keys such as `compliance`, never the transcript.

---

## 3. Template for a new network

Save as `registries\my_network.hocon` (the file name = the front man's name). Copy, then replace the
`<PLACEHOLDERS>`.

```hocon
# <ONE SENTENCE: what this network does and who calls it>
{
    "metadata": {
        "description": "<what the network does>",
        "tags": ["qa", "<topic>"],
        "sample_queries": []
    },

    # The model every agent in this file uses. Today: Gemini Nano through the bridge. See section 6 for the cloud.
    "llm_config": {
        "class": "langchain_openai.chat_models.ChatOpenAI",
        "model_name": "gemini-nano",
        "openai_api_base": "http://127.0.0.1:8000/v1",
        "openai_api_key": "local-nano",
        "temperature": 0.0
    },

    # Always set both limits so a network can never loop forever.
    "max_steps": 40,
    "max_execution_seconds": 900,

    "tools": [
        {
            # 1. FRONT MAN: same name as the file. It only delegates.
            "name": "my_network",
            "function": { "description": "<what I do, in one sentence>" },
            "instructions": """
You coordinate <the job>.
Call <specialist> once for <each item in the request>. Do not do the work yourself.
When everything is handled, reply with: <Done sentence>.
""",
            "allow": { "to_upstream": { "sly_data": ["<result key>"] } },
            "tools": ["<specialist>"]
        },

        {
            # 2. SPECIALIST: one narrow job, called with an argument.
            "name": "<specialist>",
            "function": {
                "description": "<what I do, one sentence>",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "<arg>": { "type": "string", "description": "<what this value is>" }
                    },
                    "required": ["<arg>"]
                }
            },
            "instructions": """
You do ONE job: <job>. You are given <arg>.
Step 1: call <load_tool> with <arg>. It returns <data>.
Step 2: <decide / write>. Use only what the data shows.
Step 3: call <save_tool> with <arg> and <result fields>.
Step 4: reply with: Recorded.
""",
            "tools": ["<load_tool>", "<save_tool>"]
        },

        {
            # 3. CODED TOOL that reads: Python, no AI.
            "name": "<load_tool>",
            "function": {
                "description": "<what it returns>",
                "parameters": { "type": "object",
                                "properties": { "<arg>": { "type": "string", "description": "<value>" } },
                                "required": ["<arg>"] }
            },
            "class": "<load_tool_file>.<LoadToolClass>"
        },

        {
            # 4. CODED TOOL that saves: Python, no AI.
            "name": "<save_tool>",
            "function": {
                "description": "<what it records>",
                "parameters": { "type": "object",
                                "properties": { "<arg>": { "type": "string", "description": "<value>" },
                                                "<result>": { "type": "string", "description": "<value>" } },
                                "required": ["<arg>", "<result>"] }
            },
            "class": "<save_tool_file>.<SaveToolClass>"
        }
    ]
}
```

Then:
1. Register it in `registries\manifest.hocon` (add `"my_network.hocon": true`).
2. Create `coded_tools\my_network\` with one Python file per coded tool (template below).
3. Validate: `python -m neuro_san_studio validate registries\my_network.hocon`
4. Restart the Neuro SAN server and try it in the Studio (`http://127.0.0.1:4173`).

### Template for a coded tool

`coded_tools\my_network\<load_tool_file>.py` (the folder name matches the network name):

```python
"""Coded tool: <one line>."""

from typing import Any

from neuro_san.interfaces.coded_tool import CodedTool


class LoadToolClass(CodedTool):
    """<What it returns and where the data comes from (sly_data key).>"""

    async def async_invoke(self, args: dict[str, Any], sly_data: dict[str, Any]) -> str:
        """Returns the data for ``args["<arg>"]`` from ``sly_data``; never guesses."""
        key: str = str(args.get("<arg>") or "").strip()
        item = (sly_data.get("<data key>") or {}).get(key)
        if item is None:
            return f"There is no item called '{key}'."
        return str(item)
```

A saving tool writes into `sly_data` instead (`sly_data.setdefault("<result key>", {})[key] = {...}`) and returns a
short confirmation.

---

## 4. Working examples to copy from

| What | File | Pattern |
|---|---|---|
| Audit (judge a call) | `registries\qa_audit.hocon` + `coded_tools\qa_audit\` | Coordinator, one auditor per check, `load_check` and `record_verdict` |
| **Performance agent** | `registries\qa_report.hocon` + `coded_tools\qa_report\` | Coordinator, `coach_writer`, tools `load_stats` and `record_report` |
| **Research agent** | `registries\qa_research.hocon` + `coded_tools\qa_research\` | Coordinator, `rubric_advisor`, tools `load_findings` and `propose_change` |
| Assistant | `registries\qa_assistant.hocon` | Answers staff questions from a data pack |

The Python side that feeds each network and stores its result:
`qa_engine\report_handler.py` + `performance_stats.py`, `qa_engine\research_handler.py` + `findings_builder.py`.

**Performance agent (what it does).** The worker computes an agent's statistics in plain Python (average score,
fail rate per check, trend). The AI only *describes* them: a short coaching report with strengths, weaknesses and next
steps. The numbers are never produced by the AI.

**Research agent (what it does).** For each rubric check, it reads the current rules, the corrections human reviewers
made to wrong AI verdicts and policy excerpts, then proposes clearer rules. Proposals are saved as **pending change
requests**. Nothing changes until an admin approves it in the dashboard. The AI never edits a rubric on its own.

> Status: these two networks, their handlers and the SQL (`supabase\platform_setup.sql`) are written and covered by
> unit tests with scripted models. They have not yet been run on the real model, so treat them as a working draft to
> review, tune and extend, not as finished.

---

## 5. Checklist for a good agent

- One role, one job. If the instructions need "and also…", make a second agent.
- Instructions as numbered steps ("Step 1: call X…"), ending with the exact sentence to reply.
- Tell it what NOT to do ("Do not judge anything yourself").
- Big data in `sly_data`, never copied through a prompt.
- Scores, counts and percentages computed in Python.
- `max_steps` and `max_execution_seconds` set.
- A unit test for each coded tool (see `tests\qa_engine\`).

---

## 6. Moving to the cloud model (Gemini Flash)

The switch is built in. You do not edit the agent files: one setting in `.env` decides, and the launcher applies it.

### Where to set the API key

In the engine's **`.env`** file (never in a `.hocon`, never in git):

```text
AI_PROVIDER=gemini
GOOGLE_API_KEY=<the key>
GEMINI_MODEL=gemini-2.5-flash
```

| Setting | Meaning |
|---|---|
| `AI_PROVIDER` | `nano` (default, Chrome's on-device model) or `gemini` (cloud) |
| `GOOGLE_API_KEY` | The Gemini API key. Required when `AI_PROVIDER=gemini` |
| `GEMINI_MODEL` | Model id. Default `gemini-2.5-flash`. Neuro SAN also knows the `gemini-3...` flash models |
| `GEMINI_TEMPERATURE` | Optional. Empty = automatic (0.0, or 1.0 for Gemini 3 models, as Neuro SAN's guide advises) |

On an installed engine: edit the `.env`, run `C:\QAEngine\launcher\Update-secrets.cmd`, then Stop and Start
(see `Installation guide.md`, Part 7). The `.env` template is `packaging\env.template`.

### What the switch changes

| Piece | File | Change |
|---|---|---|
| Model of every agent | `registries\qa_*.hocon`, the block between `# BEGIN LLM_CONFIG` and `# END LLM_CONFIG` | Rewritten by `switch_llm.py` (class `qa_engine\llm_switch.py`) at every start. Nothing else in the network changes |
| Call summary | `qa_engine\gemini_client.py`, chosen in `qa_engine\runner_factory.py` | Cloud summary instead of Chrome's Summarizer |
| Launcher | `packaging\launcher\start.ps1` | In cloud mode it does not start Chrome or the bridge and does not wait for the model |
| Secret check | `packaging\launcher\common.ps1`, installer | `GOOGLE_API_KEY` is required when `AI_PROVIDER=gemini` |

Manual use on a development machine:

```powershell
python switch_llm.py gemini      # point the agent networks at the cloud model
python switch_llm.py nano        # back to Chrome's Gemini Nano
```

(`GOOGLE_API_KEY` must be in the environment or `.env`.) The networks are the only files edited; running it twice
changes nothing the second time.

### Rules to keep

- The key lives only in `.env`. The Gemini client sends it in a header, so it does not appear in logs or URLs.
- Gemini calls tools natively, so the bridge's tool-calling adapter is not used in cloud mode.
- Do one network at a time when you compare, with `evaluate_samples.py` and the answer key.
- **Data protection first:** the call text is sent to Google. The PII masking has known gaps (CVV, PIN, expiry date,
  address, international phone, IBAN). Extend `preprocessor.py` and get approval before real customer calls are sent.
- With a cloud model the five-check rubric becomes practical, and parallel auditors no longer queue.

### Status

The switch is covered by unit tests (the hocon rewrite is reversible and idempotent, the Gemini client is tested with a
fake HTTP layer, and a switched network passes Neuro SAN's own `validate`). It has **not** been run against the real
Gemini API yet, because the key had not been issued when it was written. The first real run should be:
`AI_PROVIDER=gemini`, then `python evaluate_samples.py`, and compare with the answer key.
