# 02 — Chat & Paper Retrieval: Technical Specification

Scope: the user-facing chat that retrieves relevant research papers for a query and answers
with citations. Everything here is implementable from this document plus
`specs/openapi.yaml`, `specs/graph-schema.cypher`, `specs/prompts.md`.

## 1. Functional requirements

| ID | Requirement |
|----|-------------|
| F1 | A user can ask a free-text question and receive a streamed answer with inline numbered citations that resolve to paper + passage |
| F2 | The response lists the retrieved papers (title, authors, venue, year, DOI/PMID, relevance score, why-matched explanation) |
| F3 | Follow-up questions use conversation history (last 10 turns) and keep retrieved context when the query is a refinement |
| F4 | Users can apply filters: year range, source, organism, study type, open-access only, exclude retracted (default on) |
| F5 | Users can ask relationship questions ("which papers link BRCA1 to PARP inhibitor resistance?") and get a graph neighborhood view |
| F6 | Every answer is reproducible: the stored message contains the chunk ids, article versions, prompt version and model id used |
| F7 | If no sufficiently relevant evidence exists, the system says so and does not fabricate |
| F8 | Users can give feedback (thumbs, "wrong citation") on each message |
| F9 | Historical queries: `as_of=<date>` restricts retrieval to article versions current at that date |

Non-functional: p95 first token ≤ 2.5 s, p95 complete ≤ 10 s, availability 99.5 %,
≤ 0.5 % answers with any unresolved citation, cost ≤ $0.05 per turn average.

## 2. Components

```
Browser (Next.js)  ──SSE──▶  API (FastAPI)
                              ├─ auth / rate limit / guardrails
                              ├─ QueryUnderstanding  (Claude Opus 5.5, structured output)
                              ├─ Retriever           (Neo4j: vector + BM25 + RRF)
                              ├─ GraphExpander       (Neo4j: bounded traversals)
                              ├─ Reranker            (Bedrock Rerank)
                              ├─ ContextBuilder      (dedup, budget, document blocks)
                              ├─ Generator           (Claude Opus 5.5, streaming, citations)
                              └─ Persistence         (DynamoDB sessions/messages)
```

Language/runtime: Python 3.12, FastAPI, `anthropic[bedrock]` SDK (`AnthropicBedrockMantle`
client), `boto3` (Bedrock Runtime for embeddings/rerank/guardrails), `neo4j` driver 5.x.
Frontend: Next.js 15, TypeScript, `fetch` + `ReadableStream` for SSE, Cytoscape.js for graph view.

## 3. API contract (summary; full spec in `specs/openapi.yaml`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/v1/chat/sessions` | Create session |
| POST | `/v1/chat/sessions/{session_id}/messages` | Send user message; returns `text/event-stream` |
| GET | `/v1/chat/sessions/{session_id}` | Session with messages and citations |
| POST | `/v1/search/papers` | Non-conversational retrieval (same pipeline minus generation) |
| GET | `/v1/papers/{article_id}` | Paper metadata, versions, linked entities |
| GET | `/v1/papers/{article_id}/graph` | Neighborhood for visualization |
| POST | `/v1/messages/{message_id}/feedback` | Feedback |
| GET | `/v1/metrics/summary` | Dashboard data (admin/curator) |

SSE event types: `status` (stage name), `papers` (candidate list after rerank),
`delta` (answer text), `citation` (index → chunk/article/version/span), `usage`,
`done`, `error`.

## 4. Pipeline stages in detail

### 4.1 Guardrails and preprocessing

- `ApplyGuardrail` (Bedrock) on the raw user input with source `INPUT`: PII anonymization
  (names, emails, MRNs), denied topic "individual medical advice", prompt-attack filter.
  If blocked → return `error` SSE with a safe message; log category only.
- Normalize whitespace, trim to 2 000 characters, detect language (fastText); non-English
  queries are translated by the understanding step and retrieval runs in English.

### 4.2 Query understanding (Claude Opus 5.5, effort `low`, structured output)

Input: last 10 turns (summarized if > 3 k tokens) + current message + available filter
vocabulary. Output schema (strict):

```json
{
  "intent": "lookup | synthesis | relationship | comparison | clarification | out_of_scope",
  "standalone_query": "string",
  "search_queries": ["string"],           // 1–3 lexical variants
  "entities": [{"text": "BRCA1", "type": "Gene", "ontology_id": "HGNC:1100", "confidence": 0.93}],
  "filters": {"year_from": 2018, "year_to": null, "organism": ["human"], "study_type": [], "open_access_only": false},
  "needs_clarification": false,
  "clarifying_question": null,
  "reuse_previous_context": false
}
```

Rules: `out_of_scope` short-circuits with a canned reply; `clarification` returns the
question; `reuse_previous_context=true` and intent `synthesis` skips retrieval and
reuses the prior turn's context (saves ~40 % cost on follow-ups). Entities are linked by
exact ontology lookup in Neo4j first; the LLM's `ontology_id` is only a hint.

### 4.3 Hybrid retrieval (Neo4j)

Embedding of `standalone_query` with Titan V2 (`normalize=true`, 1024-d). One Cypher call
runs both searches and fuses them:

```cypher
// $qvec, $queries (list), $k=40, $as_of (date or null), $filters
CALL {
  CALL db.index.vector.queryNodes('chunk_embedding', $k, $qvec) YIELD node AS c, score
  RETURN c, score, 'vec' AS src
  UNION ALL
  UNWIND $queries AS q
  CALL db.index.fulltext.queryNodes('chunk_text', q, {limit: $k}) YIELD node AS c, score
  RETURN c, score, 'bm25' AS src
}
WITH c, src, score
MATCH (c)<-[:HAS_CHUNK]-(p:Paper)
WHERE c.is_current = true
  AND p.retracted = false
  AND ($filters.year_from IS NULL OR p.year >= $filters.year_from)
  AND ($filters.year_to   IS NULL OR p.year <= $filters.year_to)
WITH c, p, src, score
ORDER BY src, score DESC
WITH src, collect({c: c, p: p}) AS ranked
UNWIND range(0, size(ranked)-1) AS i
WITH ranked[i].c AS c, ranked[i].p AS p, 1.0 / (60 + i) AS rrf     // RRF, k=60
WITH c, p, sum(rrf) AS fused
ORDER BY fused DESC LIMIT 40
RETURN c.chunk_id, c.text, c.section, p.article_id, p.version, p.title, p.year, fused
```

For `as_of` queries, `c.is_current = true` is replaced by
`c.valid_from <= $as_of AND (c.valid_to IS NULL OR c.valid_to > $as_of)`.

### 4.4 Graph expansion (bounded)

Executed only when intent ∈ {`relationship`, `synthesis`, `comparison`} or ≥ 1 linked
entity exists. Budget: ≤ 2 hops, ≤ 30 additional papers, ≤ 120 ms.

| Expansion | Cypher sketch | Why |
|-----------|---------------|-----|
| Entity-pair co-mention | `MATCH (e1:Entity {id:$a})<-[:MENTIONS]-(p)-[:MENTIONS]->(e2:Entity {id:$b})` | Relationship questions |
| Typed relation evidence | `MATCH (e1)-[r:ASSOCIATED_WITH\|TREATS\|INHIBITS]->(e2) RETURN r.evidence_chunk_ids` | Direct evidence spans |
| Citation neighborhood | `MATCH (p)-[:CITES]->(q)` and `(q)-[:CITES]->(p)` for top-10 papers, ordered by `q.citation_count` | Seminal and follow-up work |
| Same cohort / dataset | `MATCH (p)-[:USES_DATASET]->(d)<-[:USES_DATASET]-(q)` | Comparison questions |

Expanded papers contribute their best chunk (by vector similarity to the query, computed in
the same transaction) so the reranker compares chunks, not papers. Each candidate carries a
`why_matched` label (`vector`, `lexical`, `entity:BRCA1↔PARP`, `cites:<id>`) shown in the UI.

### 4.5 Rerank and thresholding

- Bedrock Rerank (`cohere.rerank-v3-5`), query = `standalone_query`, documents = ≤ 70 chunk
  texts prefixed with paper title and section.
- Keep top 8 with `relevance_score ≥ 0.35`; require ≥ 2 chunks ≥ 0.50 to proceed to
  generation. Otherwise respond with the "insufficient evidence" template and the top
  papers marked *weak match*. Thresholds are config (doc 05 §3).
- Diversity: at most 3 chunks per paper; at least 3 distinct papers when available.

### 4.6 Context assembly

- Each chunk becomes a `document` content block (`type: "text"` source) with
  `citations: {enabled: true}`, `title = "<Paper title> (<year>) [<article_id>@<version>]"`,
  `context = "section: <section>; doi: <doi>"`.
- Order: rerank score descending; total budget 12 000 tokens (count with the SDK token
  counter; truncate lowest-ranked first).
- Conversation history: last 10 turns, assistant turns stripped to text (no document
  blocks) to keep the prompt small.
- Prompt caching: system prompt + tool/schema definitions carry `cache_control` (1 h TTL);
  document blocks are not cached (they change per query).

### 4.7 Generation

- Model `anthropic.claude-opus-5-5`; `output_config.effort = "medium"`; thinking adaptive
  (default on this model); `max_tokens = 4000`; streaming via `messages.stream`.
- Citations mode on: text blocks arrive with `citations[]` of type `char_location`; the API
  maps `document_index` → chunk → `[n]` marker and emits `citation` SSE events.
- Stop reasons: `max_tokens` → append a truncation notice; `refusal` → safe message with
  `stop_details.category` logged. On Bedrock, register the SDK's client-side refusal
  fallback middleware with `anthropic.claude-opus-4-8` as fallback.
- Output guardrail: `ApplyGuardrail` with source `OUTPUT` on the full text before `done`.
  Blocked output replaces the streamed text with a notice (UI handles `error` after `delta`).

### 4.8 Persistence and audit

Message record (DynamoDB `messages`):

```json
{
  "session_id": "...", "ts": 1733000000123, "message_id": "ulid", "role": "assistant",
  "text": "...", "citations": [{"n": 1, "chunk_id": "...", "article_id": "...", "version": 3, "start": 120, "end": 310}],
  "retrieval": {"candidates": 68, "kept": 8, "why": {...}, "rerank_min": 0.41},
  "model": "anthropic.claude-opus-5-5", "prompt_version": "chat-v7", "schema_version": "qu-v3",
  "usage": {"input": 9120, "cached": 7700, "output": 640}, "latency_ms": {"understand": 820, "retrieve": 210, "expand": 95, "rerank": 380, "ttft": 1150, "total": 6900}
}
```

## 5. Data model touched by chat

| Node | Key properties |
|------|----------------|
| `Paper` | `article_id`, `version`, `is_current`, `title`, `abstract`, `year`, `venue`, `doi`, `pmid`, `authors[]`, `retracted`, `citation_count`, `source`, `open_access` |
| `Chunk` | `chunk_id`, `chunk_hash`, `text`, `section`, `position`, `embedding` (1024 float), `embedding_model`, `is_current`, `valid_from`, `valid_to` |
| `Entity` | `id` (ontology-prefixed), `name`, `type`, `aliases[]`, `ontology` |
| `Dataset`, `Method`, `Cohort` | `id`, `name`, `source_url` |

Relationships: `(Paper)-[:HAS_CHUNK]->(Chunk)`, `(Paper)-[:MENTIONS {count, chunk_ids}]->(Entity)`,
`(Entity)-[:ASSOCIATED_WITH|TREATS|INHIBITS|… {evidence_chunk_ids, confidence, paper_ids}]->(Entity)`,
`(Paper)-[:CITES]->(Paper)`, `(Paper)-[:USES_DATASET]->(Dataset)`, `(Paper)-[:USES_METHOD]->(Method)`,
`(Paper)-[:SUPERSEDES]->(Paper)` (version chain). Full DDL in `specs/graph-schema.cypher`.

## 6. Frontend behaviour

- Chat pane streams tokens; citation markers `[n]` are clickable → side panel with passage
  highlighted, paper metadata, "open DOI", "why matched".
- Paper list updates on the `papers` event before the answer starts (perceived latency).
- Graph tab renders the retrieved neighborhood (papers, entities, relations) from
  `/v1/papers/{id}/graph` with hop control (1–2).
- Filters persist per session; "exclude retracted" default on, retracted papers appear
  greyed with a badge if the user opts in.
- Feedback buttons post to `/feedback`; "wrong citation" opens a passage picker.

## 7. Configuration (SSM parameters)

| Parameter | Default |
|-----------|---------|
| `/minerva/chat/model` | `anthropic.claude-opus-5-5` |
| `/minerva/chat/effort` | `medium` |
| `/minerva/retrieval/k_vector` / `k_bm25` | 40 / 40 |
| `/minerva/retrieval/rrf_k` | 60 |
| `/minerva/expand/max_hops` / `max_papers` | 2 / 30 |
| `/minerva/rerank/keep` / `min_score` / `min_strong` | 8 / 0.35 / 0.50 (≥ 2 chunks) |
| `/minerva/context/max_tokens` | 12000 |
| `/minerva/history/turns` | 10 |
| `/minerva/ratelimit/per_user_per_min` | 20 |

## 8. Failure handling

| Failure | Behaviour |
|---------|-----------|
| Neo4j unavailable | 503 with `Retry-After`; readiness probe fails; ASG does not restart app (DB issue) |
| Bedrock throttling (429) | SDK retries (max 2, backoff); then degrade: skip rerank (use RRF order) and retry generation once; emit `status: degraded` |
| Rerank error | Fall back to RRF order; mark `rerank: skipped` in audit |
| Understanding output fails schema | Retry once; then use raw query as `standalone_query`, no entities |
| Generation refusal | Safe message; no retry on same model; fallback middleware |
| SSE client disconnect | Cancel Bedrock stream; persist partial as `aborted` |

## 9. Testing strategy (unit/integration; quality evals are in doc 05)

- Unit: RRF fusion, threshold gating, citation index mapping, context budget truncation,
  Cypher query builders (parameterization; no string interpolation).
- Integration: Neo4j testcontainer seeded with 200 papers; recorded Bedrock responses
  (VCR-style) for deterministic CI; live smoke test nightly against Bedrock.
- Contract: OpenAPI schema validation on every response; SSE event ordering test.
- Load: k6, 100 concurrent sessions, 20 min, assert p95 TTFT ≤ 2.5 s with cache warm.
