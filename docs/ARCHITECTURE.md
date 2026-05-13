# MarbleBee RAG — Architecture

## Goal

A production-grade Retrieval Augmented Generation system that lets an AI voice agent answer caller questions about MarbleBee's products, pricing, delivery, and policies — strictly using content from `marblebee.com` as the knowledge source — and gracefully escalates to a human ticket when it isn't confident enough to answer.

The system is designed for a real B2B operation, not a demo. It assumes the website grows over time, the catalog evolves, multiple operators may handle escalations, and answer quality must be measurable and improvable.

---

## High-level architecture

```
┌──────────────┐                                                        ┌──────────────┐
│ Caller       │                                                        │ marblebee.com│
│ (Twilio)     │                                                        │ (HTML pages) │
└──────┬───────┘                                                        └──────┬───────┘
       │ inbound call                                                          │
       ▼                                                                       │ daily crawl
┌──────────────────────────────────────────┐                          ┌────────▼────────┐
│ Workflow 02 — Call Handler               │                          │ Workflow 01     │
│                                          │                          │ Indexing        │
│  /webhook/incoming-call → greeting       │                          │                 │
│  /webhook/process-speech                 │                          │  fetch sitemap  │
│      ├─ Hangup intent? ─► <Hangup/>      │                          │  for each URL:  │
│      ├─ Empty? ─► reprompt + <Hangup/>   │                          │   fetch HTML    │
│      └─ Ack TwiML response (<500ms)      │                          │   strip + hash  │
│         + RAG runs in background:        │  ┌────────────────────┐  │   diff vs DB    │
│            ├─ Has prior context (Redis)? │  │ Supabase (PG)      │  │   chunk 512/64  │
│            │   ├─ yes → context-check    │  │  marblebee_*       │◄─┤   embed         │
│            │   │       LLM → maybe done  │  │  hybrid_match RPC  │  │   upsert        │
│            │   └─ no  → full RAG         │  └─────────┬──────────┘  └─────────────────┘
│            │      rewrite → embed →      │            │ vector + BM25
│            │      hybrid search (RRF) →  │            │
│            │      fuse → diversify →     │            ▼
│            │      generate (gpt-4o-mini) │  ┌────────────────────┐
│            ├─ Save answer:{sid} ─────────┼─►│ Redis              │
│            └─ Save context:{sid} ────────┼─►│  answer:{sid}       │
│                                          │  │  context:{sid}      │
│  /webhook/answer-ready (poll loop)       │  │  chat-history:{sid} │
│      ├─ answer ready → speak it +        │  └─────────┬──────────┘
│      │                <Gather> follow-up │            │
│      │                + DELETE answer    │            │
│      ├─ not ready  → "Still checking..." │            │
│      │              + <Pause> + redirect │            │
│      └─ 6 attempts → escalation TwiML    │            │
│                                          │            │
│  /webhook/call-status (on hangup) ───────┼────────────┘
│      DELETE chat-history + answer +      │  evict per-call cache
│             context keys for that sid    │
│                                          │
│  Confidence < 0.85 → Sheet + Email + log │
└──────────────────────────────────────────┘
```

Two distinct workflows run on different schedules and have independent failure domains:

- **Workflow 01** (offline, scheduled or manual) — keeps the Supabase index fresh.
- **Workflow 02** (online, per-call) — handles every voice interaction asynchronously: ack first, run RAG in the background, poll a Redis-backed cache for the answer.

Supabase is the long-lived source of truth (chunks + query log). Redis is the short-lived per-call coordination layer (chat memory + answer/context cache, all keyed by Twilio's `CallSid`, with TTLs and explicit cleanup on hangup).

---

## Component decisions

### Vector store: Supabase / pgvector

| | Supabase | Pinecone | Qdrant Cloud | Chroma |
|---|---|---|---|---|
| Free tier | 500MB Postgres + 2 GB egress | 1 index, 100k vectors | 1 GB | self-host only |
| Hybrid (vector + BM25) | ✅ native via Postgres FTS | ❌ | ⚠ partial | ❌ |
| SQL filtering on metadata | ✅ first-class | ⚠ limited | ✅ | ⚠ |
| Built-in support in n8n | ✅ first-class node | ✅ | ✅ | ⚠ community |
| Cost at scale | predictable Postgres pricing | per-vector pricing | per-cluster | self-hosted ops |
| Operational maturity | Postgres (well-understood) | hosted, opaque | hosted | DIY |

**Picked Supabase** for hybrid search support, SQL-native metadata filters, free tier sufficient for thousands of pages, and operational familiarity (it's just Postgres).

### Embedding model: `text-embedding-3-small`

| | text-embedding-3-small | text-embedding-3-large | text-embedding-ada-002 |
|---|---|---|---|
| Dimensions | 1536 | 3072 | 1536 |
| Quality (MTEB) | 62.3 | 64.6 | 61.0 |
| Cost | $0.02 / 1M tokens | $0.13 / 1M tokens | $0.10 / 1M tokens |
| Storage size | 6 KB / vector | 12 KB / vector | 6 KB / vector |

**Picked `text-embedding-3-small`** — the price-performance sweet spot. Same dimensionality as ada-002 but better quality and 5× cheaper. Reserve `text-embedding-3-large` for measured retrieval-quality issues.

### Chat model: `gpt-4o-mini`

For both query rewriting and final RAG generation. ~$0.15 per 1M input / $0.60 per 1M output. A typical call costs **< $0.001** in LLM fees. Upgrade path to `gpt-4o` is one parameter change if quality demands it.

### Chunking: recursive 512 tokens / 64 overlap

Splits on paragraph → sentence → word boundaries. 512-token chunks fit roughly one section of marketing copy and stay well under the 8191-token embedding model limit. 64-token overlap (~12%) preserves cross-boundary context for questions that straddle two paragraphs.

### Retrieval: hybrid (vector + BM25 via RRF)

Vector search alone fails on:
- Exact product names (`Black Galaxy granite`)
- SKU codes
- Numeric specs (`5/8 inch slab`)
- Brand-specific terminology

BM25 / full-text search alone fails on:
- Conceptual questions (`do you have anything that looks like marble but cheaper?` → quartz)
- Synonyms / paraphrases

We combine both via **Reciprocal Rank Fusion** (RRF):

```
score(doc) = 1 / (k + rank_vector) + 1 / (k + rank_fts)
```

Where `k = 50` is a smoothing constant. RRF is parameter-free, robust, and consistently outperforms pure vector search on real queries.

### Source diversification

After retrieving the top 8 chunks, we cap at 2 chunks per source URL. Without this, a single product page would dominate the context for any question about that product. The LLM ends up with broader perspective, and citations span more pages.

### Confidence enforcement

The model returns `confidence: 0.0-1.0` and the parser enforces a hard floor (default 0.9). This is **independent** of the model's `intent` field — even if the model says `intent: "answered"` with 80% confidence, the parser overrides to `escalate`. This guards against the well-known LLM tendency to be overconfident on unfamiliar topics.

### Async ack + poll loop (no dead air)

Twilio TwiML is fundamentally sequential — you can't "play music while processing the same webhook." The call handler decouples the two with a Redis-mediated ack/poll pattern:

1. The speech webhook returns an ack TwiML (`<Say>Let me look that up...</Say><Pause length="3"/><Redirect>/webhook/answer-ready?sid=...</Redirect>`) in <500ms.
2. n8n keeps executing the workflow downstream of the `Respond to Webhook` node — RAG runs in parallel with Twilio playing the ack.
3. RAG eventually writes `answer:{CallSid}` to Redis with a 90s TTL.
4. Twilio's `<Redirect>` hits `/webhook/answer-ready`. That webhook reads `answer:{CallSid}` from Redis:
    - **Found** → speak it, `<Gather>` for follow-up, then DELETE the key (so the next turn doesn't read stale data).
    - **Not found** → return `<Pause><Say>Still checking...</Say><Redirect>...&attempt=N+1</Redirect>` (~5s cycle). Caps at attempt 6.

This guarantees the caller never hears silence. The longest gap between voice playback is the ~3s `<Pause>` between "Still checking" announces.

### Context reuse for follow-ups (Path A fast path)

Most multi-turn calls are *"Do you have X?" → "What's the price?" → "How heavy is it?"* — same product, follow-up questions. A naive design would re-run the full retrieval pipeline (~1–2s of Supabase work) for each follow-up. We avoid that by caching the retrieved chunks per call:

1. After every successful full-RAG turn, `Save Context to Redis` writes `context:{CallSid}` (TTL 600s) with the formatted context block + source URLs.
2. On the next turn, `Load Prior Context` reads it. If present, `Try Answer From Context` (a small gpt-4o-mini call, ~700ms) decides whether the new question can be answered from those prior chunks.
3. If yes → the LLM's answer is forwarded straight to `Save Memory Messages` and `Save Answer to Redis`. Embedding, hybrid search, fusion, diversification, context build, and the larger Generate Answer call are all skipped.
4. If no (`intent: need_retrieval` or confidence < threshold) → fall through to full RAG. No regression vs. the no-cache path.

The two parsers (`Parse Context Answer` and `Parse RAG Response`) produce the same shape of `$json`, and a `Finalized Answer` Code passthrough merges both paths into a single downstream chain. Save Memory Messages, Save Answer to Redis, the escalation fan-out, and Log Query → Supabase all read via `$('Finalized Answer')` so they don't care which path produced the answer.

### Hangup intent (skip RAG when caller is saying goodbye)

A `Classify Intent` Code node sits right after `Extract Speech Fields`. It aggressively normalizes the transcript (strip punctuation, collapse whitespace, lowercase) and matches against a list of regex patterns plus a heuristic fallback (short utterance + "thanks" + no question word → goodbye).

Matched goodbye phrases:
- "no thank you" / "no thanks" (including "no, no. thank you.")
- "goodbye", "bye bye", "thank you goodbye"
- "that's all", "that's it", "that's fine", "that's enough", "that's good"
- "nothing else", "nothing more", "that will be all"
- "we're done", "i'm done", "we're good", "i'm good", "we're all set"
- "have a good/nice/great day/night/evening/one"
- bare "no", "nope", "nah", "okay", "ok", "sure", "thanks", "thank you"

When matched, return a single goodbye TwiML + `<Hangup/>`. Saves an LLM call, an embedding call, and a hybrid search round-trip — all completely wasted work for a goodbye. Also avoids the awkward UX of a bot trying to retrieve products in response to "no thanks."

### Query logging for evaluation

Every retrieval call writes a row to `marblebee_query_log` with:
- Raw and rewritten query
- Retrieved chunk IDs and scores
- Source URLs consulted
- AI's intent, confidence, and final response
- Whether it escalated
- Response time

This is the foundation for measuring quality. See [EVALUATION.md](./EVALUATION.md).

---

## Data flow per call

A single speech turn touches two webhooks: `/webhook/process-speech` (the speech-result handler, which responds in <500ms with an ack and continues RAG in the background) and `/webhook/answer-ready` (Twilio's polling endpoint, fired every ~5s by `<Redirect>` until the answer is ready).

### Foreground (what Twilio sees)

1. **Speech webhook** receives the transcript (Twilio's STT already done).
2. **Classify Intent** — short Code node detects goodbye phrases (*"no thanks"*, *"goodbye"*, *"that's all"*, etc.). If matched → goodbye TwiML + `<Hangup/>` immediately, no RAG.
3. **Empty Transcript?** — if the caller said nothing, return a single goodbye + `<Hangup/>` (no retry loop).
4. **Build Ack TwiML** — `<Say>Let me look that up for you, one moment.</Say><Pause length="3"/><Redirect>/webhook/answer-ready?sid={CallSid}&attempt=1</Redirect>`.
5. **Respond TwiML (Ack)** — sent back to Twilio in <500ms. The caller hears the ack while we run RAG in the background. n8n keeps executing downstream nodes after this respond fires.
6. **Twilio polls** `/webhook/answer-ready` per the redirect:
    - **Answer ready in Redis** → speak it + `<Gather>` for a follow-up + DELETE `answer:{CallSid}`.
    - **Not ready yet** → `<Pause length="3"/><Say>Still checking, just a moment.</Say><Redirect>...&attempt=N+1</Redirect>` (~5s per cycle).
    - **Attempt ≥ 6** → graceful escalation TwiML + `<Hangup/>`.

### Background (RAG pipeline, running while Twilio plays the ack)

7. **Get Memory Messages** + **Format History** — load chat memory from Redis (`chat-history:{CallSid}`), format prior turns + cited sources for the prompt.
8. **Load Prior Context** (Redis GET `context:{CallSid}`):
    - **Found** → run **Try Answer From Context** (gpt-4o-mini, small prompt, ~700ms): "given these prior chunks and the new question, can you answer? Return `intent: answered` with the response, or `intent: need_retrieval`."
        - **Confident answer** → write to `answer:{CallSid}`, save chat memory, log to Supabase. Skip the rest of RAG. **Total background time: ~1.5–3s.**
        - **need_retrieval or low confidence** → fall through to step 9.
    - **Not found** → step 9.
9. **Query Rewrite** (gpt-4o-mini, ~200ms) — turn *"yeah uh do you have any of that black sparkly stone for countertops"* into 2–3 self-contained variants like `["Black Galaxy granite countertop", "black sparkly granite slab"]`. The literal transcript is appended as a fallback variant.
10. **Embed** all variants in one batched call to `text-embedding-3-small` (~300–500ms, 2.5s timeout).
11. **Hybrid Search** — `hybrid_match_marblebee(query_text, query_embedding, match_count=5)` RPC fired in parallel for each variant (n8n `batchSize=10`, 2.5s timeout).
12. **Fuse Retrievals** — Reciprocal Rank Fusion across variants. Optional anchor-boost: if any variant token-overlaps with a previously cited URL, multiply that source's score by 2× and (if needed) pin its chunks via a direct PostgREST GET.
13. **Diversify Retrievals** — cap at 2 chunks per `source_url`.
14. **Build Context** — format kept chunks with source numbers + URLs, capped at 4500 chars total (≤ 900 chars per chunk). Also fans out a parallel branch to **Save Context to Redis** (`context:{CallSid}` = `{contextBlock, sourceUrls, chunksUsed}`, TTL 600s) so the next turn can use Path A.
15. **Generate Answer** (gpt-4o-mini, ~1.5–4s) — strict prompt with worked examples, anti-hallucination rules ("never carry over prices/dimensions from prior conversation"), and a 4-step decision rubric. Outputs JSON with `intent`, `confidence`, `spoken_response`, `sources`, `reasoning`.
16. **Parse RAG Response** — lenient JSON parsing (3 fallback strategies), enforce confidence ≥ 0.85, downgrade to `escalate` if below.
17. **Finalized Answer** (Code passthrough) — both Path A (`Parse Context Answer`) and Path B (`Parse RAG Response`) feed into this single node so all downstream consumers read from one place.
18. **Save Memory Messages** — append `{user, ai}` pair to Redis chat memory for the next turn's prompt.
19. **Save Answer to Redis** — `SETEX answer:{CallSid} 90 = {intent, spokenResponse, sources, callSid}`. The next poll from `/webhook/answer-ready` finds it and serves it.
20. **Log Query → Supabase** — fire-and-forget write of the full retrieval + outcome for evaluation.
21. **Can AI Answer?** — if `intent == "escalate"`, fan out to Google Sheet ticket row + email notification.

### Cleanup

22. **Twilio call-status webhook** fires on hangup → `Clear Session` → DELETE `chat-history:{CallSid}` → DELETE `answer:{CallSid}` → DELETE `context:{CallSid}` → 200 OK. Belt-and-suspenders alongside the `Delete Served Answer` that fires after each successful poll-loop serve and the explicit TTLs on every key.

### Latency budgets

| Path | Background work | Caller-perceived first-answer time |
|---|---|---|
| **Path A — context reuse** (same product follow-up) | ~1.5–3s | ~3–5s (ack ~2s + first poll ~2–4s after Twilio's STT) |
| **Path B — full RAG** | ~5–8s | ~7–11s (caller hears ack + one or two "Still checking..." cycles) |
| **Path B — slow tail (gpt-4o-mini cold)** | ~10–14s | up to ~16s before the 6-attempt cap kicks in |

The 6-poll cap × ~5s each = ~24s ceiling. Beyond that the caller hears a graceful escalation TwiML instead of dead air.

---

## Failure handling

Every step that can fail externally is wrapped in `continueOnFail` with a defined fallback:

| Step | Fails how? | Fallback behaviour |
|---|---|---|
| Query Rewrite (OpenAI) | API timeout / rate limit | Extract Rewritten falls back to the literal transcript as the only variant |
| Embed Query (OpenAI) | API timeout / rate limit (2.5s cap) | Empty embedding → hybrid search returns lexical-only results for that variant |
| Hybrid Search (Supabase) | DB unreachable (2.5s cap) | Variant contributes nothing to fusion; remaining variants still rank |
| Try Answer From Context (OpenAI) | Timeout / parse error | Falls through to full-RAG Path B |
| Generate Answer (OpenAI) | Timeout / parse error | Parse RAG Response's fallback returns `intent: escalate` with a generic spoken response |
| Save Answer to Redis | Redis unreachable | Poll loop exhausts 6 attempts → graceful escalation TwiML. n8n logs the failure. |
| Save Context to Redis | Redis unreachable | Next turn won't have a Path A fast path; it just runs full RAG. No caller impact. |
| Log Query (Supabase) | DB write fail | Logged in n8n execution log; no caller impact |
| Sheet write | Quota / auth | Email still goes; surfaced in n8n executions |
| Email send | Gmail quota / auth | Sheet row still written |
| Voice response | Twilio call dropped | Background RAG completes anyway. Call-status webhook clears Redis state. |
| /webhook/answer-ready not registered | n8n config issue | Twilio receives 404 on the redirect → drops the call with error 11200. **Always re-save + re-activate the workflow after importing.** |

The principle is: **a single component failure should never cause the caller to hear silence**. The async ack pattern means the caller hears voice within a few seconds of finishing speaking — n8n's ack response itself is under 500ms, with Twilio's speech-recognition endpointing dominating the 3–5s caller-perceived window — regardless of whether the background RAG ever completes. At worst they get a 24-second polite "still checking" loop ending in a graceful escalation message, never silence or a Twilio error tone.

---

## Cost model

For a small site (~50 pages) and ~500 calls/month:

**Indexing (daily, idempotent):**
- Re-index of changed pages only — typically ≤ 5 pages/day after the initial run
- Embedding cost: ~$0.0001 / page → ~$0.005 / day → **~$0.15 / month**

**Per call:**
- Query rewrite: 100 input + 30 output tokens of `gpt-4o-mini` = $0.000033
- Query embedding: 20 tokens of `text-embedding-3-small` = $0.0000004
- Hybrid search: free (Supabase free tier)
- Generation: 1500 input + 200 output tokens of `gpt-4o-mini` = $0.000345
- **Total LLM ≈ $0.0004 / call**

For 500 calls/month: **~$0.20/month in LLM costs**.

Voice (Twilio inbound + Polly TTS): ~$0.08 / minute. The dominant cost is voice, not AI.

---

## Scaling considerations

The current design handles MarbleBee's likely scale (a few thousand pages, a few thousand calls/month) with no architectural changes. At larger scale, the levers are:

| Scale point | Current limit | Upgrade path |
|---|---|---|
| Number of indexed chunks | ~100k (IVFFlat) | Switch to HNSW: `create index ... using hnsw (embedding vector_cosine_ops)` |
| Concurrent calls | ~50/sec (n8n single-instance) | Horizontal scale n8n; use Twilio task router to queue |
| Index freshness | Daily | Trigger 01 from a Supabase webhook on CMS publish |
| Multi-language | English only | Add `language` metadata column, filter at retrieval |
| Multi-tenant (multiple businesses) | Single tenant | Enable RLS in Supabase; tag chunks with `tenant_id` |
| Re-ranking precision | Top-K of hybrid search | Add a cross-encoder re-rank step (`bge-reranker-base`) |

---

## Why this is genuinely RAG

For comparison, the previous "RAG-flavored" workflow:

| Aspect | Previous workflow | This workflow |
|---|---|---|
| Knowledge source | Hardcoded in system prompt | Live Supabase index from `marblebee.com` |
| Retrieval | None — full page dumped to LLM | Vector + BM25 hybrid, top-K with diversification |
| Scalability | Caps at single page (~12k chars) | Tens of thousands of chunks, sub-second retrieval |
| Citation | Impossible | Every answer carries source URLs |
| Evaluation | Impossible | Every query logged with retrievals + outcome |
| Update cadence | Edit prompt and redeploy | Indexer runs daily, no workflow edits |
| Token cost / call | High (12k chars in prompt every time) | Low (only relevant chunks, ~6× cheaper) |
| Quality on large catalogs | Doesn't work | Designed to scale |

This is what production teams mean by RAG: **a separate index lifecycle, semantic + lexical retrieval, source attribution, and a measurable feedback loop**.

See [SELF_CRITIQUE.md](./SELF_CRITIQUE.md) for an honest audit of where this design still has gaps.
