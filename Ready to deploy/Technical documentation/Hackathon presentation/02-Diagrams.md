# Diagrams

Use these when someone asks "how does that connect?". Each one has a sentence you can say while pointing at it.

## 1. The big picture

```mermaid
flowchart TB
    subgraph PEOPLE["People"]
        M["Managers and supervisors<br/>browser"]
        F["Transcript files<br/>inbox folder"]
    end
    subgraph CLOUD["Cloud: shows and stores"]
        V["Vercel<br/>web app (FastAPI + HTML/JS)"]
        S[("Supabase<br/>Auth + Postgres + RLS<br/>transcripts, rubric, scores, jobs queue")]
    end
    subgraph ENGINE["Engine laptop: thinks"]
        W["Watcher<br/>masks PII, uploads"]
        K["Worker<br/>claims jobs, scores in code"]
        N["Neuro SAN server :8080<br/>5 agent networks + coded tools"]
        B["Bridge :8000<br/>OpenAI-style API + tool-calling adapter"]
        C["Chrome :9222<br/>Gemini Nano on device"]
    end
    G["Cloud Gemini<br/>(AI_PROVIDER=gemini)"]
    M -->|"upload, dashboard, rubric"| V
    V <-->|"read / write"| S
    F --> W
    W -->|"audit job"| S
    S -->|"claim job"| K
    K -->|"streaming_chat + sly_data"| N
    N -->|"/v1/chat/completions"| B
    B -->|"Playwright / DevTools"| C
    N -.->|"cloud mode"| G
    N -->|"verdicts"| K
    K -->|"score + findings"| S
```

<div class="say"><p>The cloud shows and stores, the laptop thinks, and the jobs queue connects them. The website never calls the engine.</p></div>

## 2. One audit, end to end

```mermaid
sequenceDiagram
    participant UI as Web app
    participant DB as Supabase
    participant WK as Worker
    participant NS as Neuro SAN agents
    participant BR as Bridge
    participant AI as Gemini Nano
    UI->>DB: save transcript + job (queued)
    WK->>DB: claim_job()
    DB-->>WK: job + transcript + rubric (this tenant only)
    WK->>WK: mask PII, compute facts (identity order)
    loop one task per rubric check
        WK->>NS: check task, data in sly_data
        NS->>BR: chat completion with tools
        BR->>AI: prompt (temperature 0)
        AI-->>BR: JSON reply
        BR-->>NS: tool call or answer
        NS-->>WK: verdict (pass/fail + reason)
    end
    WK->>WK: guard critical fails, compute score
    WK->>DB: save score + flags
    DB-->>UI: dashboard shows the result
```

<div class="say"><p>Notice that the model only ever sees one small task at a time, and everything before and after it is deterministic code.</p></div>

## 3. The agent teams and who calls them

```mermaid
flowchart LR
    K["Worker<br/>one job kind per team"]
    subgraph TEAMS["Four specialist teams (Neuro SAN agent networks)"]
        direction TB
        A["qa_audit<br/>judges a call"]
        R["qa_report<br/>coaching report"]
        X["qa_research<br/>proposes better rules"]
        Q["qa_assistant<br/>answers questions"]
    end
    P["qa_platform<br/>router, for demos"]
    K -->|"audit"| A
    K -->|"report"| R
    K -->|"research"| X
    K -->|"chat"| Q
    P -.->|"demo: can call any of them"| TEAMS
```

<div class="say"><p>The worker dispatches by job kind. The teams do not call each other: only the demo router does.</p></div>

## 4. How the teams are connected: through the data

```mermaid
flowchart LR
    AU["qa_audit"] -->|"scores"| SC[("audit scores")]
    SC -->|"statistics"| RE["qa_report"]
    SC --> AS["qa_assistant"]
    SC -->|"human corrections"| FB[("rule_feedback")]
    FB --> RS["qa_research"]
    KB[("knowledge base<br/>policy text")] --> RS
    RS -->|"proposal"| AD{"Admin approves?"}
    AD -->|"yes"| RB[("new rubric version")]
    RB -->|"the next audit uses it"| AU
```

<div class="say"><p>Audits feed reports and the assistant, corrections feed the researcher, and an approved rule change changes the next audit. A person approves the one step that changes behaviour.</p></div>

## 5. Inside the audit team

```mermaid
flowchart TB
    W["Worker<br/>1 request: Checks to run"]
    F["qa_audit<br/>coordinator (AI)"]
    A1["check_auditor<br/>one per check (AI)"]
    L["load_check<br/>Python tool"]
    RV["record_verdict<br/>Python tool"]
    S[("sly_data<br/>private channel<br/>tasks in, verdicts out")]
    W --> F
    F -->|"one call per check key"| A1
    A1 -->|"1. get my task"| L
    A1 -->|"2. record my verdict"| RV
    L <-.-> S
    RV -.-> S
    S -.->|"verdicts back to the worker"| W
```

<div class="say"><p>Two agents think, two tools act. The transcript never goes through a prompt: the models pass short keys, and the tools read the real data from sly_data.</p></div>

## 6. Why a bridge, and how the model can change

```mermaid
flowchart LR
    NS["Neuro SAN agents<br/>speak OpenAI chat + tools"]
    CFG{{"llm_config<br/>one block per network"}}
    BR["Bridge<br/>translator + tool-calling adapter"]
    NANO["Chrome Gemini Nano<br/>window.LanguageModel"]
    GEM["Gemini in the cloud<br/>API key"]
    VX["Vertex AI<br/>service account or login (planned)"]
    OL["Ollama local models<br/>(idea to evaluate)"]
    NS --> CFG
    CFG -->|"today"| BR
    BR --> NANO
    CFG -->|"AI_PROVIDER=gemini"| GEM
    CFG -.->|"if keys are blocked"| VX
    CFG -.->|"alternative"| OL
```

<div class="say"><p>Because Neuro SAN reads the model from one block, we change where the thinking happens without touching the agents.</p></div>

## 7. Tenant isolation

```mermaid
flowchart TB
    U["User logs in"]
    H["Login hook adds tenant_id + user_role<br/>to the token"]
    RLS["Row-level security<br/>every table: tenant_id = my tenant"]
    ROWS["Only my company's rows"]
    WK["Worker (restricted qa_worker role)"]
    SC["set_config app.current_tenant<br/>per job, per transaction"]
    SK["Service key<br/>only in Vercel, only for admin API"]
    U --> H --> RLS --> ROWS
    WK --> SC --> RLS
    SK -.->|"never in the browser, never in the engine"| ROWS
```

<div class="say"><p>Isolation is enforced by the database, not by the website: even a bug in the page could not read another company's rows.</p></div>

## 8. The learning loop

```mermaid
flowchart LR
    AU["Audit<br/>AI verdicts"] --> REV["Human review<br/>Review and edit score"]
    REV -->|"changed verdict"| FB[("rule_feedback<br/>AI said / human decided")]
    FB -->|"2 examples per check<br/>shown to the auditors"| AU
    FB --> RES["Research agent<br/>needs 2+ corrections or a matching policy"]
    KB[("Knowledge base<br/>policy text")] --> RES
    RES --> PR["Proposal: new rules + reason"]
    PR --> AP{"Admin approves?"}
    AP -->|"yes"| RUB["New rubric version<br/>old ones kept"]
    AP -->|"no"| REJ["Rejected, nothing changes"]
    RUB --> AU
```

<div class="say"><p>Two kinds of learning: immediate (corrected examples shown to the auditors) and governed (rule changes that a person approves).</p></div>

## 9. Making a small model trustworthy

```mermaid
flowchart LR
    T["Call text"] --> M["Mask PII<br/>code"]
    M --> FA["Computed facts<br/>code: identity order"]
    FA --> AG["Agents propose verdicts<br/>AI"]
    AG --> OV["Identity check decided<br/>by the computed facts"]
    OV --> GU["Critical-fail guard<br/>must quote the agent"]
    GU --> SC["Score<br/>code: weights + critical rule"]
    SC --> NR{"Unproven critical fail?"}
    NR -->|"yes"| FLAG["NEEDS REVIEW flag<br/>a person decides"]
    NR -->|"no"| RES["Result"]
    FLAG --> RES
```

<div class="say"><p>Rule of thumb we followed: the AI judges what needs judgment; code decides what can be counted.</p></div>

## 10. Delivering it to the managers

```mermaid
flowchart LR
    DEV["Developer<br/>build_package.ps1"] --> PK["Ready to deploy<br/>zip + installer + docs"]
    PK --> MG["Manager runs Install.cmd"]
    MG --> ST["C:\\QAEngine<br/>app/1.4.x, data, launcher"]
    ST --> RUN["Start: supervisor<br/>restarts, keeps PC awake"]
    SEC[".env sent privately"] -.-> MG
    NEW["New version"] -->|"Install.cmd again, settings kept"| ST
    ST -.->|"rollback: edit current.txt"| OLD["Previous version"]
```

## 11. The main data tables

```mermaid
erDiagram
    TENANTS ||--o{ USERS : has
    TENANTS ||--o{ RUBRICS : owns
    TENANTS ||--o{ TRANSCRIPTS : owns
    TRANSCRIPTS ||--o{ AUDIT_SCORES : scored_by
    TRANSCRIPTS ||--o{ JOBS : queued_as
    AUDIT_SCORES ||--o{ RULE_FEEDBACK : corrected_in
    TRANSCRIPTS ||--o{ REVIEW_REQUESTS : contested_in
    RUBRICS ||--o{ RUBRIC_CHANGE_REQUESTS : proposed_for
    TENANTS ||--o{ KNOWLEDGE_BASE_DOCS : stores
    TENANTS ||--o{ PERFORMANCE_REPORTS : receives
    TENANTS ||--o{ AUDIT_TRAIL : logs
```

<div class="say"><p>Every table carries the tenant, which is what makes the isolation rule one line of policy on each of them.</p></div>
