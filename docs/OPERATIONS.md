# OPERATIONS.md — Runbook

Day-to-day operations of the MarbleBee RAG system: setup, monitoring, common tasks, and incident response.

---

## 1. One-time setup

### 1.1 Supabase project

1. Sign in at [supabase.com](https://supabase.com) → **New Project**
2. Project name: `marblebee-rag-prod`
3. Region: pick one close to your callers (e.g. `us-east-1` for NY-based callers)
4. Database password: store in your password manager
5. Wait ~2 minutes for provisioning

### 1.2 Run the schema

1. Supabase dashboard → **SQL Editor** → **+ New query**
2. Paste the entire contents of [`sql/supabase_schema.sql`](../sql/supabase_schema.sql)
3. Click **Run**. Should return success in < 5 seconds.
4. Verify with:
   ```sql
   select * from marblebee_index_health;
   ```
   You should see one row of zeros (nothing indexed yet).

### 1.3 Capture credentials

In Supabase: **Settings → API**

- **Project URL** — looks like `https://xxxxxxxxxxxx.supabase.co`
- **service_role key** — under "Project API keys" (NOT the anon key)

Treat the `service_role` key like a database root password. Do not check it into git.

### 1.4 n8n credentials to create

| Credential type | Used by | What to put |
|---|---|---|
| `OpenAI API` | OpenAI nodes (rewrite, context-check, generate, embed) | Your OpenAI API key |
| `Redis` | Chat memory + per-call answer/context cache + hangup cleanup | Host, port, password (Upstash free tier works fine) |
| `Google Sheets OAuth2 API` | Sheets ticket node | Google account that owns the Sheet |
| `Gmail OAuth2 API` | Email node | Gmail account to send from |
| `Supabase API` (optional) | If you swap HTTP nodes for native Supabase node | URL + service role key |

The Redis credential is **required** for workflow 02. There are 8 nodes that depend on it: `Redis Chat Memory (Get)`, `Redis Chat Memory (Save)`, `Save Answer to Redis`, `Save Context to Redis`, `Load Prior Context`, `Read Redis Answer`, `Delete Served Answer`, plus the three hangup-cleanup deletes. After import, verify each one shows the credential bound.

### 1.5 Plug values into the workflows

Open both workflow JSON files and search for these placeholders **before importing**:

| Placeholder | Replace with |
|---|---|
| `https://YOUR_PROJECT_REF.supabase.co` | Your Supabase Project URL |
| `REPLACE_WITH_SUPABASE_SERVICE_ROLE_KEY` | Your service_role key |

You can also leave them as-is, import, and edit the **RAG Config** / **Supabase Config** Set nodes inside n8n. Both approaches work; the second keeps secrets out of the JSON file.

### 1.6 Import workflows

1. n8n → **Workflows** → **Import from File** → `01_indexing_workflow.json`
2. Repeat for `02_call_handler_workflow.json`
3. For each workflow, attach the credentials to:
   - All HTTP Request nodes that call OpenAI (Authentication = Predefined Credential Type → OpenAI API)
   - The Embeddings (OpenAI) sub-node in workflow 01
   - The Vector Store Insert (Supabase) node — needs `Supabase API` credential
   - Google Sheets node
   - Gmail node

### 1.7 Twilio configuration

1. Twilio Console → **Phone Numbers → Active Numbers** → click your number
2. **Voice Configuration → A call comes in → Webhook**
   - URL: `https://<your-n8n-domain>/webhook/incoming-call`
   - Method: POST
3. **Voice Configuration → Call status changes**
   - URL: `https://<your-n8n-domain>/webhook/call-status`
   - Method: POST
   - Subscribe to events: `completed`, `busy`, `no-answer`, `failed`, `canceled`
4. Save

The call-status webhook is what wipes Redis state when the caller hangs up. Without it, `chat-history:{CallSid}`, `answer:{CallSid}`, and `context:{CallSid}` will sit in Redis until their TTLs (1800s / 90s / 600s respectively) expire. Not catastrophic — just wasteful.

### 1.7a Internal webhooks (do NOT configure in Twilio)

These are reachable on the same n8n domain but are only ever hit by Twilio's `<Redirect>` from inside an active call:

| URL | Purpose |
|---|---|
| `POST /webhook/process-speech` | Speech-result handler. Linked from the `<Gather action="...">` inside ack and follow-up TwiML. |
| `POST /webhook/answer-ready` | Poll loop. Linked from the `<Redirect>` inside ack and "Still checking..." TwiML. |

After importing the workflow JSON, **save + re-activate the workflow in n8n** so all four webhooks register. If `/webhook/answer-ready` doesn't register, every call will drop right after the ack with Twilio error 11200.

### 1.8 First indexing run

1. Open workflow `01_indexing_workflow.json` in n8n → **Execute Workflow** (manual trigger)
2. Watch the executions tab; expect ~30 seconds for a small site
3. Check email for the indexing report
4. Verify in Supabase SQL editor:
   ```sql
   select * from marblebee_index_health;
   select count(*), source_url from marblebee_documents group by source_url order by count(*) desc;
   ```

### 1.9 Activate the call handler

Workflow `02_call_handler_workflow.json` → toggle **Active** in the top-right.

You're live.

---

## 2. Daily / weekly monitoring

### 2.1 Index health (quick glance)

```sql
select * from marblebee_index_health;
```

Watch for:
- `oldest_index` more than 48 hours old → indexer not running
- `escalation_rate_24h_pct` > 50% → retrieval quality dropped (or marblebee.com changed substantially)
- `avg_confidence_24h` trending down → same warning

### 2.2 Recent escalations to review

```sql
select id, created_at, raw_transcript, ai_confidence, retrieved_urls
from marblebee_query_log
where escalated and created_at > now() - interval '7 days'
order by created_at desc
limit 50;
```

Review each: was the escalation correct? If not, that signals a retrieval gap. Add a label:

```sql
update marblebee_query_log
set reviewer_label = 'missing_info'   -- or 'wrong', 'partial', 'good'
where id = 12345;
```

Aim for ≥ 30 labeled rows/week. This becomes the gold set for evaluation (see [EVALUATION.md](./EVALUATION.md)).

### 2.3 Weekly index refresh check

The schedule trigger fires daily at 03:00 New York time. Verify by checking n8n's **Executions** tab filtered to workflow 01.

If recent runs are missing, n8n may have been down — re-run manually.

---

## 3. Common operational tasks

### 3.1 Force a full re-index

When you've added a major new section to marblebee.com and don't want to wait for the daily refresh:

1. Workflow 01 → **Execute Workflow**
2. Watch the email report
3. Verify the new URLs appear:
   ```sql
   select url, last_indexed_at from marblebee_sources order by last_indexed_at desc limit 10;
   ```

### 3.2 Force re-index of a specific page only

```sql
-- Mark the page as needing refresh (deletes its hash):
update marblebee_sources set content_hash = 'force-refresh' where url = 'https://marblebee.com/products';
-- Then run workflow 01 manually.
```

### 3.3 Remove a page from the index

If a URL should never be indexed (e.g. it was added by mistake):

1. Add its path prefix to the `blockPathPatterns` field in the **Indexing Config** Set node of workflow 01
2. Then delete the existing chunks:
   ```sql
   select delete_marblebee_chunks_by_source('https://marblebee.com/wrong-page');
   delete from marblebee_sources where url = 'https://marblebee.com/wrong-page';
   ```

### 3.4 Reset the entire index (start fresh)

```sql
truncate marblebee_documents, marblebee_sources cascade;
-- Then run workflow 01 manually for a full re-index.
```

Query log is preserved (it's separate from the index data).

### 3.5 Maintenance after large insertions

After the first big indexing run, refresh the planner statistics:

```sql
analyze marblebee_documents;
analyze marblebee_sources;
```

Postgres re-runs `analyze` automatically over time, but doing it once after a bulk load makes the first hours of queries faster.

### 3.6 Tune the confidence threshold

If you find legitimate questions are escalating too often, drop the threshold:

1. Workflow 02 → **RAG Config** node → `confidenceThreshold` field
2. Try `0.85` instead of `0.9`. Save and reactivate.
3. Watch escalation rate over the next 50 calls.

If wrong answers start slipping through, raise it. The right value depends on your tolerance for false positives vs false negatives.

### 3.7 Increase retrieval breadth

If the AI keeps escalating because it lacks context:

1. Workflow 02 → **RAG Config** node → `topK` field
2. Bump from `5` → `8` or `10` (more chunks retrieved → bigger LLM context → higher cost per call)
3. The `Build Context` node enforces a 4500-char cap (and a 900-char per-chunk cap) so context stays bounded.

### 3.8 Tune the poll loop

The "Still checking, just a moment" announces are controlled by `Build Still Working TwiML`. Variables:

- **Pause length**: currently `<Pause length="3"/>` before the announce. Increase to 4–5s if you want fewer announces during a slow tail.
- **Max attempts**: `Extract Poll Fields` → `maxAttempts` (default 6). Each attempt is ~5s, so 6 = ~24s ceiling before graceful escalation.

Lowering `maxAttempts` to 4 means the call escalates sooner on a stuck RAG. Raising to 8 means the caller waits up to 40s before hearing the escalation.

### 3.9 Clear the per-call cache mid-call

If you need to force a fresh retrieval mid-call (e.g. a stale context chunk is poisoning follow-ups):

```bash
redis-cli DEL "context:CAxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
redis-cli DEL "answer:CAxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

The next speech turn will fall through to full RAG.

### 3.10 Add new goodbye phrases

Edit the `Classify Intent` Code node. The `goodbyePatterns` array is a list of regex literals. Add new patterns to either:
- The regex list (for explicit phrases)
- The heuristic fallback at the bottom (for "short utterance + thanks + no question word" style detection)

Test changes by tracing through the workflow with a custom transcript before activating.

---

## 4. Incident response

### 4.1 "Calls not connecting"

1. Twilio Console → **Monitor → Logs → Calls** — does the call appear?
   - **No** → carrier-side issue, contact Twilio support
   - **Yes, status = `failed`** → check error code in the row
   - **Yes, status = `completed`** → call reached Twilio; n8n is the issue

2. If n8n: open https://<your-n8n-host> — does the UI load?
3. n8n → **Workflows** → is workflow 02 marked **Active**?
4. Make a test curl:
   ```bash
   curl -i -X POST https://<your-n8n-host>/webhook/incoming-call \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "CallSid=DIAG&From=%2B14155551234&To=%2B1XXXXXXXXXX"
   ```
   Should return TwiML XML in 200ms.

### 4.2 "AI is escalating everything"

Two probable causes:

**A. Retrieval is returning no chunks.** Check:
```sql
select count(*) from marblebee_documents;
```
If 0 → the indexer hasn't run successfully. Run workflow 01 manually.

**B. Retrieval is returning irrelevant chunks.** Check a recent escalation:
```sql
select retrieved_urls, retrieval_scores
from marblebee_query_log where id = <recent escalation id>;
```
If max score < 0.4, the question is genuinely outside the indexed content. That escalation is correct behavior.

### 4.3 "AI gave a wrong answer with high confidence"

This is the worst failure mode. Triage:

1. Find the row in `marblebee_query_log`
2. Note the `retrieved_urls` and `ai_confidence`
3. Re-read those URLs manually — does the answer come from there?
   - **Yes, but the page itself is wrong** → fix marblebee.com first, then re-index
   - **No, the model invented it** → tighten the system prompt with an explicit "do not infer beyond the chunks" rule, and consider implementing finding #7 from [SELF_CRITIQUE.md](./SELF_CRITIQUE.md) (citation-overlap check)

Label the row `wrong` so it shows up in the weekly report.

### 4.4 "Index is stale"

```sql
select max(last_indexed_at), min(last_indexed_at) from marblebee_sources;
```

If `max` is more than 48 hours old:
- Check workflow 01 schedule trigger is enabled
- Check n8n hasn't been down (look at server logs)
- Manually trigger workflow 01 once

### 4.5 "Caller hears the ack but then the call drops"

Symptom: caller speaks, hears *"Let me look that up for you, one moment"*, then dead silence and the call ends. n8n executions show `/webhook/process-speech` running (and finishing in the background) but no `/webhook/answer-ready` execution.

**Root cause: the `Twilio: Answer Ready` webhook hasn't been registered with n8n.** This happens after a fresh import if you didn't save + re-activate the workflow.

Fix:
1. Open workflow 02 in n8n editor.
2. Click **Save** in the top right.
3. Toggle the **Active** switch off, then back on.
4. Test in the browser: `https://<your-n8n>/webhook/answer-ready` — should return *"This webhook is not registered for GET requests"* or similar 405. If it returns a 404, the webhook isn't live.
5. Make a fresh test call.

### 4.6 "Caller hears the previous turn's answer, then a different one"

Symptom: caller asks turn 2, hears the turn-1 answer played back during the poll loop, then eventually hears the correct turn-2 answer.

**Root cause: stale `answer:{CallSid}` in Redis from the previous turn.** The fix (`Delete Served Answer` node after `Respond TwiML (Polled Answer)`) should clear it, but if the workflow was imported before that node existed, it won't.

Verify:
1. Open `Respond TwiML (Polled Answer)` in workflow 02. Its output should connect to `Delete Served Answer` (Redis delete on key `answer:{{ $('Extract Poll Fields').first().json.sid }}`).
2. If missing, re-import the latest JSON.

### 4.7 "Redis is down"

Symptom: every call escalates. n8n executions show red on the Redis nodes.

`Save Memory Messages`, `Save Answer to Redis`, `Save Context to Redis`, and the chat-memory subnodes are all marked `continueOnFail: true`. Failures don't crash the call, but:
- Without `Save Answer to Redis`, the poll loop never finds an answer → escalation TwiML after 6 attempts.
- Without chat memory, every turn looks like the first turn (no context, no follow-up resolution).

Fix: bring Redis back. Upstash free tier rarely fails; if you self-host, check `redis-cli PING`.

While Redis is down, the workflow degrades gracefully (single-turn answers via full RAG every time), but caller experience is the 24s poll-then-escalate path.

### 4.8 "Email / Sheets writes failing silently"

Both nodes have `continueOnFail: true`, so failures don't crash the call. To find them:

n8n → **Executions** filter:
- Workflow: `MarbleBee RAG — 02 Call Handler`
- Status: `Success` (yes — escalations show as success even if Email failed)

Click any escalation execution → look for red on the Email or Sheets node. The error message tells you what's wrong (usually OAuth re-auth needed or quota).

---

## 5. Cost monitoring

Sources of spend:

| Item | Where to check | Approximate scale |
|---|---|---|
| OpenAI (embed + chat) | https://platform.openai.com/usage | $0.0004 per turn (full RAG) / $0.0002 per turn (context-reuse hit) + $0.005 per indexing run |
| Twilio voice | console.twilio.com → Usage | $0.085/min inbound, $0.04/min Polly TTS |
| Supabase | supabase.com → Project → Reports | Free tier covers ~ 500 MB DB + 2 GB egress |
| Redis | Upstash free tier or self-host | Free tier covers 10k commands/day — far more than the per-call traffic |
| n8n | self-hosted = compute cost | negligible at this scale |

Set OpenAI usage limits at the API key level: Settings → Billing → Usage limits. Recommended:
- **Soft limit**: $20/month (warning email)
- **Hard limit**: $100/month (cuts off API)

Even if cost runs away due to a misconfiguration, you cap exposure.

---

## 6. Backups and disaster recovery

### 6.1 What's recoverable

- **Supabase** — Pro plan includes daily backups for 7 days. Free tier does NOT. **For production, upgrade Supabase to Pro ($25/month) or take manual exports.**
- **n8n workflows** — exported as JSON files in this folder. Re-import to recover.
- **Sheets / Email logs** — historical record of escalations.

### 6.2 Manual export of the vector index

If you don't want to pay for Supabase Pro:

```bash
pg_dump "postgresql://postgres:<password>@db.<project_ref>.supabase.co:5432/postgres" \
  --table marblebee_documents \
  --table marblebee_sources \
  --table marblebee_query_log \
  --data-only \
  --file marblebee_rag_backup_$(date +%Y%m%d).sql
```

Run weekly via cron. Restore is a single `psql ... -f backup.sql`.

### 6.3 If the index is lost

The index is reconstructible from `marblebee.com` itself: just run workflow 01 manually. Total recovery time for a small site: ~5 minutes + ~$0.05 in re-embedding cost.

---

## 7. Security checklist

- [ ] OpenAI API key stored as n8n credential (not in workflow JSON)
- [ ] Supabase service_role key stored as n8n credential
- [ ] `marblebee_query_log.raw_transcript` reviewed for accidental PII (see [SELF_CRITIQUE.md](./SELF_CRITIQUE.md) #6)
- [ ] Twilio `X-Twilio-Signature` validation enabled (see [SELF_CRITIQUE.md](./SELF_CRITIQUE.md) #9)
- [ ] OpenAI usage limits set
- [ ] Supabase RLS policies enabled if multi-tenant
- [ ] HTTPS-only on n8n public URL
- [ ] n8n itself behind authentication (basic auth or SSO)

If any of the above are unchecked, the system is not yet production-ready by enterprise standards. Several are flagged as Major in [SELF_CRITIQUE.md](./SELF_CRITIQUE.md).

---

## 8. Contact / escalation

For changes to this RAG system:
- Architecture / design: see [ARCHITECTURE.md](./ARCHITECTURE.md)
- Quality issues: see [EVALUATION.md](./EVALUATION.md)
- Known weaknesses: see [SELF_CRITIQUE.md](./SELF_CRITIQUE.md)
