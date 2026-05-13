# EVALUATION.md — Measuring & improving retrieval quality

A RAG system without measurement is a black box. This document describes how to know whether retrieval is actually working, how to compare changes objectively, and how to spot regressions early.

---

## What we measure

Three layers of quality, each with a defined metric:

| Layer | Question it answers | Metric |
|---|---|---|
| **Retrieval** | Did we find the right chunks? | `recall@K` against a labeled gold set |
| **Generation** | Given good chunks, did the LLM write a good answer? | `human-labeled accuracy` of the spoken response |
| **End-to-end** | Did the caller's question get resolved? | `escalation rate` and `caller satisfaction` |

These are deliberately separated. A bad answer can come from bad retrieval *or* bad generation; conflating them makes debugging impossible.

---

## The query log is the foundation

Every call writes a row to `marblebee_query_log`:

```sql
\d marblebee_query_log
-- id, call_sid, caller_number, raw_transcript, rewritten_query,
-- retrieved_ids, retrieval_scores, retrieved_urls,
-- ai_intent, ai_confidence, ai_response, response_ms,
-- escalated, caller_followup, reviewer_label, created_at
```

Without this table, you cannot:
- Replay a question against a new prompt or new index
- Compare retrieval-quality experiments
- Spot drift over time
- Detect spikes in escalations
- Build a gold set for evaluation

If you remember nothing else from this document: **never disable the `Log Query → Supabase` node, even if it's slow**.

---

## Building the gold set

A gold set is a curated list of (question, expected_answer_or_source) pairs that you can run through the system repeatedly to detect regressions.

### Initial bootstrap (one-time, ~2 hours of work)

1. Pull representative questions from the first 100 real calls:
   ```sql
   select id, raw_transcript, ai_intent, escalated
   from marblebee_query_log
   order by random()
   limit 30;
   ```

2. Add 20 questions from the FAQ pages of marblebee.com (you know the ground-truth answer).

3. Add 10 questions you make up that target known weaknesses (multi-turn follow-ups, ambiguous wording, exact product names, edge cases).

4. Total: **60 question gold set**. Store as a CSV in `eval/gold_set.csv` (this folder is not yet committed; create it):
   ```
   id,question,expected_url,expected_keywords,notes
   1,"What's the minimum order for marble?",https://marblebee.com/policies,"100 sq ft, minimum","standard policy"
   2,"Do you carry Black Galaxy granite?",https://marblebee.com/products/black-galaxy,"Black Galaxy, granite","exact product name"
   ...
   ```

### Maintenance (weekly, ~30 minutes)

After each week of real traffic:

1. Review escalations that should have been answered:
   ```sql
   select id, raw_transcript, retrieved_urls
   from marblebee_query_log
   where escalated and reviewer_label is null
   and created_at > now() - interval '7 days'
   order by created_at desc;
   ```

2. For each, decide: was the escalation correct?
   - If it was correct (caller wanted a custom quote, etc.) → `reviewer_label = 'good'`
   - If retrieval missed relevant content → add to gold set with the URL that *should* have been found
   - If generation gave a bad answer → `reviewer_label = 'wrong'`

3. Update the row:
   ```sql
   update marblebee_query_log
   set reviewer_label = 'missing_info',
       caller_followup = 'Should have found /products/quartz page'
   where id = 1234;
   ```

Aim for a gold set of **150–300 questions** by month two. Larger sets give more reliable measurements.

---

## Metric 1 — Retrieval recall@K

Runs the gold set through the retrieval pipeline only (no LLM generation) and measures: for each question, did the expected URL appear in the top-K retrieved chunks?

```sql
-- Build a one-shot evaluation function
create or replace function eval_retrieval_recall (
  p_question text,
  p_expected_url text,
  p_k int default 8
) returns boolean language plpgsql as $$
declare
  found boolean;
begin
  -- caller is responsible for embedding p_question first and passing it.
  -- For an internal-only stub, just run hybrid_match with full-text alone.
  select exists(
    select 1
    from hybrid_match_marblebee(
      p_question,
      array_fill(0::float8, array[1536])::vector,  -- zero embedding == lexical-only
      p_k
    )
    where (metadata ->> 'source_url') = p_expected_url
  ) into found;
  return found;
end;
$$;
```

For a real evaluation you embed each question via OpenAI and call `hybrid_match_marblebee` with the actual embedding. A small Python script or n8n eval workflow does this.

**Target:** `recall@8 >= 0.85` after the first month. Below 0.7 means retrieval is broken; investigate before tuning generation.

---

## Metric 2 — Generation accuracy (human-labeled)

For each gold-set question, run the full pipeline and have a human grade the spoken response:

| Label | Meaning |
|---|---|
| `good` | Answer is correct, well-phrased, and grounded in the retrieved chunks |
| `partial` | Right direction but missing a key detail |
| `wrong` | Confidently incorrect; this is the failure mode we hate most |
| `missing_info` | AI escalated correctly because the info isn't on the site |

Label them in `marblebee_query_log.reviewer_label`. Compute accuracy:

```sql
select
  reviewer_label,
  count(*) as n,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from marblebee_query_log
where reviewer_label is not null
  and created_at > now() - interval '30 days'
group by reviewer_label
order by n desc;
```

**Targets:**
- `good` ≥ 75%
- `wrong` ≤ 5%

A `wrong` rate above 5% means hallucination is happening. Tighten the system prompt or add a retrieval-grounded confidence + citation-overlap check.

---

## Metric 3 — End-to-end escalation rate

```sql
select
  date_trunc('day', created_at) as day,
  count(*) as calls,
  100.0 * count(*) filter (where escalated) / count(*) as escalation_pct,
  round(avg(ai_confidence)::numeric, 3) as avg_confidence
from marblebee_query_log
where created_at > now() - interval '30 days'
group by 1
order by 1 desc;
```

This is what the business cares about: how often does the AI handle a call vs punt to a human?

**Tracking it daily reveals problems early:**
- A sudden spike from 30% → 70% over two days = something broke (index, OpenAI, prompt change)
- A slow drift from 30% → 50% over a month = catalog grew or website changed; re-evaluate the gold set
- Persistently > 60% = the topK / threshold tuning is too conservative for the real workload

---

## How to compare two retrieval configurations (A/B testing)

When you want to test whether — for example — bumping `topK` from 8 to 12 helps, do **not** just deploy the change and watch metrics. Things drift; correlation isn't causation. Instead:

### Quick A/B (manual, 1 hour)

1. Run the gold set through both configurations
2. Compute `recall@K` for each
3. If they differ by less than the inverse of gold-set size (1/60 ≈ 1.7%), the difference is noise; pick whichever is simpler

### Proper A/B (production, 1 week)

1. Add a `variant` column to `marblebee_query_log`:
   ```sql
   alter table marblebee_query_log
   add column variant text default 'control';
   ```

2. In workflow 02, randomly assign:
   ```js
   const variant = Math.random() < 0.5 ? 'control' : 'experiment';
   ```
   Use `variant` to choose between configurations (different `topK`, different prompts, etc.).

3. After 200+ calls per variant, compare:
   ```sql
   select
     variant,
     count(*) as n,
     avg(ai_confidence) as avg_conf,
     100.0 * count(*) filter (where escalated) / count(*) as escalation_pct,
     count(*) filter (where reviewer_label = 'wrong') as wrong_count
   from marblebee_query_log
   where created_at > now() - interval '7 days'
   group by variant;
   ```

Statistical significance requires ~200 samples per arm for medium effect sizes. Don't make decisions on smaller samples.

---

## Common quality issues and what they look like in the data

### "Caller asks about pricing, AI keeps escalating"

```sql
select id, raw_transcript, ai_confidence, retrieved_urls
from marblebee_query_log
where ai_intent = 'escalate' and category = 'pricing'
order by created_at desc
limit 20;
```

If `retrieved_urls` doesn't include `/pricing` or `/products/*`, retrieval is missing those pages. Cause: indexing skipped them (check `marblebee_sources.status`) or chunks are too short to capture pricing context. Fix: re-index, or increase chunk size to 768.

### "AI is confidently making things up"

```sql
select id, raw_transcript, ai_response, retrieved_urls
from marblebee_query_log
where reviewer_label = 'wrong' and ai_confidence > 0.85
order by created_at desc;
```

The `ai_response` will reference details that don't appear at any of the `retrieved_urls`. Cause: model hallucination despite high self-rated confidence. Fix: implement a citation-overlap check.

### "Multi-turn conversations fall apart"

Look for `caller_followup` patterns where one question references a previous turn. Currently every turn is independent — chat history is fed into the rewriter and the final-answer prompt, but retrieval itself does not use prior turns.

### "Retrieval scores are all low (<0.4) on legitimate queries"

The query rewriter probably failed silently. Check:
```sql
select raw_transcript, rewritten_query
from marblebee_query_log
where retrieval_scores is not null
  and (select max(s) from unnest(retrieval_scores) s) < 0.4
order by created_at desc
limit 20;
```

If `rewritten_query` is empty or matches `raw_transcript` exactly, the rewrite step isn't adding value. Tighten its prompt with examples of phone-call noise → clean query.

---

## Quarterly retrieval review (1 hour, every 3 months)

1. Pull a fresh sample of 50 real questions
2. Run them through the pipeline and grade
3. Compare results to the previous quarter
4. Update the gold set with new failure modes
5. Decide: which improvements to ship next quarter
6. Document the decisions in a `CHANGELOG.md` so future-you knows what was tried

This rhythm is what separates a system that gets better from one that quietly decays.

---

## Cost-aware tuning

Many tuning levers (bigger `topK`, larger embedding model, GPT-4o instead of mini) cost more per call. Always look at quality *and* cost together:

```sql
-- Last week: cost per resolved call
select
  count(*) as calls,
  count(*) filter (where not escalated) as resolved,
  -- Approximate cost per call:
  --   query rewrite ~$0.000033, embed ~$0.0000004, generate ~$0.000345
  count(*) * 0.0004 as openai_cost_usd,
  (count(*) * 0.0004) / nullif(count(*) filter (where not escalated), 0) as cost_per_resolved
from marblebee_query_log
where created_at > now() - interval '7 days';
```

A change that improves accuracy by 2% but doubles cost-per-resolved-call is usually a bad trade.

---

## TL;DR — the loop

```
                ┌────────────────┐
                │  Real calls    │
                └───────┬────────┘
                        │
                        ▼
                ┌────────────────┐
                │ marblebee_     │
                │ query_log      │ ← every call writes a row
                └───────┬────────┘
                        │
                        ▼
              ┌──────────────────┐
              │ Weekly review    │
              │  - label rows    │
              │  - add to gold   │
              └─────────┬────────┘
                        │
                        ▼
              ┌──────────────────┐
              │ Quarterly retros │
              │  - measure       │
              │  - decide        │
              │  - implement     │
              └──────────────────┘
```

Without this loop, the system rots silently. With it, it gets measurably better every month.
