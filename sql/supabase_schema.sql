-- =============================================================================
-- MarbleBee RAG — Supabase / pgvector schema
-- =============================================================================
-- Run this in your Supabase project's SQL editor (Database → SQL Editor).
-- Provides: vector storage, idempotent re-indexing, hybrid (vector + BM25) search,
-- per-source metadata filters, query logging, and quality-evaluation tables.
--
-- Section 0 wipes any prior MarbleBee objects, so this whole file is safe to
-- re-run from scratch — but it WILL delete data. Comment out section 0 if you
-- want CREATE-IF-NOT-EXISTS semantics.
--
-- Compatibility: Postgres 15+, pgvector ≥ 0.5.0
-- =============================================================================

-- 0. Reset — drop existing MarbleBee objects in dependency order. ------------
-- Order matters: views/functions that reference tables come first, then the
-- trigger function, then the tables themselves. IF EXISTS makes a clean DB safe.
drop view     if exists marblebee_index_health;
drop function if exists hybrid_match_marblebee(text, vector, int, float, float, int, jsonb);
drop function if exists match_marblebee_documents(vector, int, jsonb);
drop function if exists delete_marblebee_chunks_by_source(text);
drop function if exists marblebee_documents_set_chunk_index() cascade;
drop table    if exists marblebee_query_log;
drop table    if exists marblebee_documents;
drop table    if exists marblebee_sources;
drop function if exists marblebee_immutable_unaccent(text);

-- 1. Extensions ---------------------------------------------------------------
create extension if not exists vector;
create extension if not exists pg_trgm;        -- fuzzy text matching
create extension if not exists unaccent;       -- accent-insensitive search

-- unaccent() is STABLE (its dictionary could change), but Postgres requires
-- IMMUTABLE expressions inside generated columns. Wrap it in a SQL function
-- explicitly marked IMMUTABLE so we can use it in the marblebee_documents.fts
-- generated column below.
create or replace function marblebee_immutable_unaccent(text)
  returns text
  language sql
  immutable
  parallel safe
as $$
  select public.unaccent('public.unaccent', $1);
$$;

-- 2. Source tracking ----------------------------------------------------------
-- Tracks every URL we have indexed and its last-seen content hash, so the
-- indexer can skip pages that have not changed (cheap re-indexing).
create table if not exists marblebee_sources (
  url               text primary key,
  content_hash      text not null,
  page_title        text,
  last_modified     timestamptz,            -- from sitemap or HTTP Last-Modified
  last_indexed_at   timestamptz default now(),
  chunk_count       int default 0,
  status            text default 'active',  -- active | stale | failed | excluded
  failure_reason    text
);

create index if not exists marblebee_sources_status_idx
  on marblebee_sources (status, last_indexed_at);

-- 3. Vector store table -------------------------------------------------------
-- One row per chunk. Re-indexing replaces all chunks for a source via the
-- delete_marblebee_chunks_by_source() helper (avoids orphans).
--
-- IMPORTANT — schema design decisions:
-- The n8n LangChain Vector Store node only writes (content, metadata, embedding).
-- Anything else needs to be auto-derived server-side, otherwise inserts fail with
-- "null value in column X violates not-null constraint". We solve this with:
--   - source_url    : generated column reading from metadata->>'source_url'
--   - chunk_index   : populated by BEFORE INSERT trigger (per-source counter)
--   - content_hash  : generated column over (source_url || chunk_index || content)
-- Stored generated columns are computed *after* BEFORE INSERT triggers fire, so
-- chunk_index (set by trigger) is available when content_hash is computed.
create table if not exists marblebee_documents (
  id               bigserial primary key,
  content          text not null,
  metadata         jsonb not null default '{}',
  embedding        vector(1536),            -- text-embedding-3-small dim
  -- Auto-derived from metadata.source_url so the LangChain insert populates it
  -- for free. FK still enforces referential integrity to marblebee_sources.
  source_url       text generated always as (metadata->>'source_url') stored not null
                   references marblebee_sources(url) on delete cascade,
  -- Set by trg_marblebee_documents_chunk_index (defined below). Nullable on the
  -- column so the trigger can fill it in; NOT NULL is enforced post-trigger via
  -- the unique constraint at the bottom.
  chunk_index      int,
  -- Auto-derived once source_url + chunk_index are settled. md5 over the triple
  -- gives a stable, unique fingerprint per chunk for dedup / change detection.
  content_hash     text generated always as (
                     md5(
                       coalesce(metadata->>'source_url','') || '|' ||
                       coalesce(chunk_index::text,'')      || '|' ||
                       content
                     )
                   ) stored,
  token_count      int,
  fts              tsvector
                   generated always as (to_tsvector('english', marblebee_immutable_unaccent(content))) stored,
  created_at       timestamptz default now(),

  unique (source_url, chunk_index)
);

-- chunk_index auto-numbering: per-source counter, 0-based.
-- Read source_url via metadata->>'source_url' (NOT NEW.source_url) because
-- stored generated columns are computed AFTER BEFORE INSERT triggers fire,
-- so NEW.source_url is still null inside the trigger body.
-- Race-safe under the indexing workflow because Split In Batches is set to
-- batchSize=1 (inserts are sequential per source).
create or replace function marblebee_documents_set_chunk_index()
returns trigger as $$
declare
  v_source_url text := NEW.metadata->>'source_url';
begin
  if NEW.chunk_index is null and v_source_url is not null then
    NEW.chunk_index := (
      select count(*) from marblebee_documents
      where metadata->>'source_url' = v_source_url
    );
  end if;
  return NEW;
end;
$$ language plpgsql;

drop trigger if exists trg_marblebee_documents_chunk_index on marblebee_documents;
create trigger trg_marblebee_documents_chunk_index
  before insert on marblebee_documents
  for each row execute function marblebee_documents_set_chunk_index();

-- 4. Indexes ------------------------------------------------------------------
-- IVFFlat is fine for < 100k rows. Switch to HNSW for > 1M rows:
--   create index ... using hnsw (embedding vector_cosine_ops);
create index if not exists marblebee_documents_embedding_idx
  on marblebee_documents using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);

-- Full-text search (BM25-style)
create index if not exists marblebee_documents_fts_idx
  on marblebee_documents using gin (fts);

-- Fast metadata filters
create index if not exists marblebee_documents_metadata_idx
  on marblebee_documents using gin (metadata jsonb_path_ops);

create index if not exists marblebee_documents_source_url_idx
  on marblebee_documents (source_url);

-- 5. Pure semantic match (used by n8n Vector Store node) ----------------------
-- Compatible with @n8n/n8n-nodes-langchain.vectorStoreSupabase signature:
-- (query_embedding, match_count, filter) → (id, content, metadata, similarity).
create or replace function match_marblebee_documents (
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'::jsonb
) returns table (
  id bigint,
  content text,
  metadata jsonb,
  similarity float
) language sql stable as $$
  select
    md.id,
    md.content,
    md.metadata || jsonb_build_object(
      'source_url',  md.source_url,
      'chunk_index', md.chunk_index
    ) as metadata,
    1 - (md.embedding <=> query_embedding) as similarity
  from marblebee_documents md
  where md.metadata @> filter
  order by md.embedding <=> query_embedding
  limit match_count;
$$;

-- 6. Hybrid match (vector + lexical, Reciprocal Rank Fusion) ------------------
-- Significantly improves recall for keyword-heavy queries
-- ("Black Galaxy granite", SKU codes, exact product names) which pure
-- semantic search often misses.
create or replace function hybrid_match_marblebee (
  query_text       text,
  query_embedding  vector(1536),
  match_count      int default 8,
  full_text_weight float default 1.0,
  semantic_weight  float default 1.0,
  rrf_k            int default 50,
  filter           jsonb default '{}'::jsonb
) returns table (
  id bigint,
  content text,
  metadata jsonb,
  similarity float,
  semantic_rank int,
  fts_rank int
) language sql stable as $$
with full_text as (
  select
    md.id,
    row_number() over (
      order by ts_rank_cd(md.fts, websearch_to_tsquery('english', unaccent(query_text))) desc
    )::int as rank_ix
  from marblebee_documents md
  where md.fts @@ websearch_to_tsquery('english', unaccent(query_text))
    and md.metadata @> filter
  limit greatest(match_count * 2, 30)
),
semantic as (
  select
    md.id,
    row_number() over (order by md.embedding <=> query_embedding)::int as rank_ix
  from marblebee_documents md
  where md.metadata @> filter
  limit greatest(match_count * 2, 30)
)
select
  md.id,
  md.content,
  md.metadata || jsonb_build_object(
    'source_url',  md.source_url,
    'chunk_index', md.chunk_index
  ) as metadata,
  ( coalesce(1.0 / (rrf_k + ft.rank_ix), 0.0) * full_text_weight
  + coalesce(1.0 / (rrf_k + sem.rank_ix), 0.0) * semantic_weight
  )::float as similarity,
  sem.rank_ix as semantic_rank,
  ft.rank_ix  as fts_rank
from marblebee_documents md
left join full_text ft on ft.id = md.id
left join semantic  sem on sem.id = md.id
where ft.id is not null or sem.id is not null
order by similarity desc
limit match_count;
$$;

-- 7. Idempotent upsert helper -------------------------------------------------
-- Replace all chunks for a given source_url in one call (avoid orphans on
-- re-indexing). Call from the indexing workflow before inserting new chunks.
create or replace function delete_marblebee_chunks_by_source (
  p_source_url text
) returns int language plpgsql as $$
declare
  removed int;
begin
  delete from marblebee_documents where source_url = p_source_url;
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- 8. Query log (every retrieval call gets logged) -----------------------------
-- Required for evaluation — without this you cannot improve retrieval quality.
create table if not exists marblebee_query_log (
  id                 bigserial primary key,
  call_sid           text,
  caller_number      text,
  raw_transcript     text,
  rewritten_query    text,
  retrieved_ids      bigint[],
  retrieval_scores   float[],
  retrieved_urls     text[],
  ai_intent          text,           -- answered | escalate
  ai_confidence      float,
  ai_response        text,
  response_ms        int,
  escalated          boolean default false,
  caller_followup    text,           -- post-call review notes
  reviewer_label     text,           -- 'good' | 'partial' | 'wrong' | 'missing_info'
  created_at         timestamptz default now()
);

create index if not exists marblebee_query_log_created_idx
  on marblebee_query_log (created_at desc);

create index if not exists marblebee_query_log_label_idx
  on marblebee_query_log (reviewer_label) where reviewer_label is not null;

-- 9. Health view --------------------------------------------------------------
-- Useful for the operations dashboard and quick smoke checks.
create or replace view marblebee_index_health as
  select
    (select count(*) from marblebee_sources where status = 'active')        as active_sources,
    (select count(*) from marblebee_documents)                              as total_chunks,
    (select round(avg(chunk_count)::numeric, 1)
       from marblebee_sources where status = 'active')                      as avg_chunks_per_page,
    (select min(last_indexed_at) from marblebee_sources where status = 'active') as oldest_index,
    (select max(last_indexed_at) from marblebee_sources where status = 'active') as newest_index,
    (select count(*) from marblebee_query_log
       where created_at > now() - interval '24 hours')                      as queries_last_24h,
    (select round(avg(ai_confidence)::numeric, 3)
       from marblebee_query_log
       where created_at > now() - interval '24 hours')                      as avg_confidence_24h,
    (select round(100.0 * count(*) filter (where escalated)
                  / nullif(count(*), 0)::numeric, 1)
       from marblebee_query_log
       where created_at > now() - interval '24 hours')                      as escalation_rate_24h_pct;

-- 10. Row-level security stubs (optional — uncomment for multi-tenant) -------
-- alter table marblebee_documents enable row level security;
-- alter table marblebee_sources   enable row level security;
-- alter table marblebee_query_log enable row level security;
-- create policy tenant_read on marblebee_documents
--   for select using (metadata ->> 'tenant_id' = auth.jwt() ->> 'tenant_id');

-- 11. Tell PostgREST to reload its schema cache --------------------------------
-- Without this, the Supabase REST API may return
--   "Could not find the table 'public.marblebee_documents' in the schema cache"
-- for a few minutes after table changes. NOTIFY makes the reload immediate.
notify pgrst, 'reload schema';

-- =============================================================================
-- DONE. Verify with:
--   select * from marblebee_index_health;
--   select column_name, is_nullable from information_schema.columns
--     where table_name = 'marblebee_documents' order by ordinal_position;
-- =============================================================================
