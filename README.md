# MarbleBee RAG — Production-grade voice agent with retrieval-augmented generation

A real RAG voice agent for **MarbleBee**, a wholesale marble, granite, and quartz supplier. Callers ask questions; an AI answers using only what's actually published on `marblebee.com`, cites the sources it used, and gracefully escalates to a human ticket when it isn't confident enough.

**Walkthrough video:** [Loom — end-to-end tour of both workflows](https://www.loom.com/share/dc6192444526414d9bbc7e12eb3cee30)

> This system is intentionally *not* a demo. It's designed to scale to a real catalog and get measurably better over time.

---

## What's in this repository

```
MarbleBee_RAG_Production/
├── README.md                          ← you are here
├── 01_indexing_workflow.json          ← n8n: crawl marblebee.com → chunk → embed → store
├── 02_call_handler_workflow.json      ← n8n: voice → retrieve → answer → escalate
├── sql/
│   └── supabase_schema.sql            ← Postgres + pgvector schema (run once in Supabase)
└── docs/
    ├── ARCHITECTURE.md                ← system design and decisions
    ├── OPERATIONS.md                  ← setup, monitoring, incident response
    └── EVALUATION.md                  ← how to measure & improve quality
```

---

## What it does

```
Caller dials Twilio number
        │
        ▼
n8n: greet (off-hours) or forward (business hours)
        │
        ▼ off-hours
Twilio gathers spoken question → POSTs to /webhook/process-speech
        │
        ▼
Hangup intent? ("no thanks", "goodbye", "that's all")
        ├──── yes ──► one-line goodbye TwiML + <Hangup/>  (RAG never runs)
        │
        └──── no ─────────┐
                          ▼
        ACK TwiML returned in <500ms: "Let me look that up..." + <Pause> + <Redirect>
        Twilio plays ack while RAG runs in the background
        │
        ▼ background
Has prior context for this CallSid in Redis?
   ├── yes ──► LLM checks if answer is in cached chunks
   │           ├── confident ──► skip retrieval, answer immediately (Path A, ~2-3s)
   │           └── not sure ───► fall through to full RAG (Path B)
   └── no  ──► full RAG (Path B)

Path B (full RAG):
   Query Rewrite (gpt-4o-mini) → 2-3 search variants
        │
        ▼
   OpenAI embeds (text-embedding-3-small, 1536-d) — one batched call
        │
        ▼
   Supabase hybrid search (vector + BM25 via RRF) — one RPC per variant, parallel
        │
        ▼
   Fuse + diversify (≤ 2 chunks per source URL) → top 5 chunks
        │
        ▼
   Build context (≤ 4500 chars total, ≤ 900 chars per chunk)
        │
        ▼
   Generate Answer (gpt-4o-mini) — JSON with intent + confidence + sources
        │
        ▼
   Parse + enforce confidence floor → write answer:{CallSid} to Redis
        │
        └─► Save context:{CallSid} to Redis (powers next-turn fast path)

Meanwhile (foreground):
   Twilio polls /webhook/answer-ready every ~5s
        ├── answer ready  ──► speak it + <Gather> for follow-up + DELETE answer:{CallSid}
        ├── still waiting ──► "Still checking..." + <Pause> + redirect again
        └── 6 attempts hit ──► graceful escalation TwiML + <Hangup/>

Confidence < 0.85 ──► escalate: Sheet row + Email + still log to Supabase
On hangup (Twilio call-status callback):
        DELETE chat-history + answer + context Redis keys for that CallSid
```

---

## Setup in 30 minutes

Detailed steps in [`docs/OPERATIONS.md`](./docs/OPERATIONS.md). High-level:

1. **Supabase project** → run [`sql/supabase_schema.sql`](./sql/supabase_schema.sql) in the SQL editor
2. **Redis** → any small Redis instance (Upstash free tier works). Used for chat-memory + per-call answer/context cache.
3. **n8n credentials** → OpenAI, Redis, Gmail, Google Sheets, Supabase
4. **Import workflows** → `01_indexing_workflow.json`, `02_call_handler_workflow.json`
5. **Plug in** your Supabase URL and service-role key (RAG Config / Supabase Config Set nodes)
6. **Run workflow 01 once** to populate the index
7. **Activate workflow 02**
8. **Twilio configuration**:
   - **Voice URL** → `POST https://<your-n8n>/webhook/incoming-call`
   - **Call status callback** → `POST https://<your-n8n>/webhook/call-status` (subscribe to: completed, busy, no-answer, failed, canceled). This clears Redis state when the call ends.

That's it. The first call goes through the full RAG pipeline.

### Loading `.env` into n8n

The workflows reference Supabase, the n8n base URL, and a few other settings via `$env.VARNAME`. Copy `.env.example` → `.env`, fill in your values, and then make sure the n8n **process** can see them — n8n does not read the `.env` file on its own. Pick whichever of these matches how you run n8n:

- **docker-compose** — point the n8n service at the file:
  ```yaml
  services:
    n8n:
      image: n8nio/n8n
      env_file: .env
  ```
- **systemd** — add the file to your unit:
  ```ini
  [Service]
  EnvironmentFile=/path/to/marblebee-rag-voice-agent/.env
  ```
- **plain shell / dev** — source it before starting n8n:
  ```bash
  set -a; source .env; set +a
  n8n start
  ```
- **n8n.cloud** — there's no filesystem to read from; paste each variable into **Settings → Variables** in the UI.

After loading, restart n8n. You can sanity-check from any Code node with `return [{ json: { sb: $env.SUPABASE_URL } }];` — if it comes back empty, the env vars didn't reach the process.

### Webhooks exposed by workflow 02

| URL | Purpose |
|---|---|
| `POST /webhook/incoming-call` | Twilio's first hop — greet or forward |
| `POST /webhook/process-speech` | Speech transcript handler — runs intent classification + ack + RAG in background |
| `POST /webhook/answer-ready` | Internal — Twilio polls this until the answer is ready, with a "Still checking..." voice loop |
| `POST /webhook/call-status` | Twilio call-status callback — wipes Redis cache on hangup |

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| Voice | Twilio (`<Gather input="speech">` + Polly Neural TTS) | Mature, reliable carrier-grade voice, $0.085/min inbound |
| Orchestration | n8n (self-hosted) | Visual workflow editor; LangChain nodes built in |
| Embeddings | OpenAI `text-embedding-3-small` | $0.02 / 1M tokens, MTEB 62.3, 1536-d |
| Vector DB | Supabase pgvector + Postgres FTS | Hybrid search native, free tier sufficient, SQL-familiar |
| Per-call cache + chat memory | Redis (Upstash free tier or self-hosted) | Sub-ms reads/writes for `answer:{sid}`, `context:{sid}`, and chat-history keys |
| LLM | OpenAI `gpt-4o-mini` for rewrite, context-check, and generation | $0.15/1M in, $0.60/1M out — ~$0.0004–$0.0008 per call |
| Tickets | Google Sheets + Gmail | Zero-maintenance, owners already have access |

Total per-call LLM cost: **~$0.0004**.
Total per-call all-in (with voice): **~$0.10/min**.

---

## What makes this RAG (and not "prompt stuffing")

Three things separate this from naive *fetch-and-paste-into-prompt*:

1. **A separate index lifecycle.** The website is crawled, chunked, and embedded ahead of time. Per-call workload is just retrieval, not re-ingestion.
2. **Hybrid retrieval with diversification.** Vector search finds semantically similar content; BM25 finds exact-match terms; RRF fuses them; per-source caps prevent any single page from dominating.
3. **A measurable feedback loop.** Every call writes to `marblebee_query_log` with retrievals, scores, and outcomes. Quality is tracked numerically, not by vibes.

Compared to the previous "RAG" prototype (one HTTP fetch + 12 K chars dumped into a prompt), this:

| | Previous prototype | This system |
|---|---|---|
| Knowledge scale | one page (~12 K chars) | unlimited (Supabase scales) |
| Token cost / call | high (whole page in every prompt) | low (only matched chunks) |
| Source attribution | impossible | every answer carries source URLs |
| Update cadence | edit the prompt | indexer runs daily, no workflow edits |
| Quality measurement | impossible | logged for every call |
| Multi-page coverage | no | yes |

---

## Cost expectations

For MarbleBee at typical small-business scale (~50 indexed pages, ~500 calls/month):

- **OpenAI**: ~$0.20/month (LLM) + $0.15/month (embeddings, daily re-index) = **$0.35/month**
- **Supabase**: free tier
- **Twilio**: dominated by per-minute voice charges (~$0.085/min), not by AI

The AI part of this system is dramatically cheaper than the voice part.

---

## Quality targets (after the first month of real traffic)

| Metric | Target | How to measure |
|---|---|---|
| `recall@5` on the gold set | ≥ 0.85 | run gold set through retrieval, see [`docs/EVALUATION.md`](./docs/EVALUATION.md) |
| Reviewer-labeled `good` answers | ≥ 75% | weekly review of `marblebee_query_log` |
| Reviewer-labeled `wrong` answers | ≤ 5% | the failure mode we hate most |
| Caller-perceived first-answer latency (p50) | ≤ 8 s | time from caller-finished-speaking → answer playback |
| Caller-perceived first-answer latency (p95) | ≤ 14 s | poll loop tops out at ~24 s before escalation |
| Follow-up answer latency (context-reuse hit) | ≤ 3 s | Path A short-circuits retrieval |
| Escalation rate | 25–40% | depends on catalog completeness |

The caller never hears dead air thanks to the async ack + poll pattern: a "Let me look that up..." prompt plays within a few seconds of the caller finishing speaking — n8n itself returns the ack TwiML in under 500ms, but Twilio's speech-recognition endpointing typically adds 2–4s before the workflow even runs, so caller-perceived ack latency is 3–5s. The poll loop then says "Still checking..." every ~5 seconds while RAG is running.

---

## Documentation map

- **Setting it up?** → [`docs/OPERATIONS.md`](./docs/OPERATIONS.md)
- **Understanding the design?** → [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)
- **Improving quality?** → [`docs/EVALUATION.md`](./docs/EVALUATION.md)

---

## Summary

A production-grade RAG voice agent with hybrid retrieval, source diversification, confidence enforcement, and a query-log-driven evaluation loop. Designed to scale to ~50k pages and ~5k calls/month on Supabase free tier.
