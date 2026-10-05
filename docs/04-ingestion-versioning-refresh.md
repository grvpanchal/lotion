# 04 — Ingestion, Article Versioning and Efficient RAG Refresh

## 1. Goals

- New and updated publications are retrievable within 24 h of appearing at the source.
- A refresh touches **only what changed**: unchanged chunks are never re-embedded or
  re-extracted.
- Readers never see a half-updated article; writes are atomic per article version.
- Every past version remains available for audit and `as_of` queries; retracted work is
  excluded from default retrieval but not deleted.
- Full rebuild (e.g., embedding-model upgrade) is possible without downtime (blue/green).

## 2. Identity and versioning model

### 2.1 Article identity

`article_id` is a stable internal ULID. Source identifiers map to it in DynamoDB
`articles` GSI `by_source_id` (`pmid`, `pmcid`, `doi`, `arxiv_id`, `biorxiv_doi`).
Resolution order on ingest: DOI → PMID → PMCID → arXiv id → title+first-author+year
fuzzy match (threshold 0.95 Jaro-Winkler on normalized title, same year ±1). Ambiguous
matches go to a `review` queue instead of auto-merging.

### 2.2 Content hash

```
normalized_doc = canonical JSON of {title, abstract, sections[{heading, text}], references[], metadata_subset}
content_hash   = sha256(normalized_doc)     # excludes volatile fields: fetch time, citation counts, source timestamps
meta_hash      = sha256({authors, venue, year, doi, pmid, retracted, open_access})
```

A new **version** is created when `content_hash` changes. A `meta_hash` change alone
(citation count, venue correction) updates the current version's properties in place
(no re-embedding). Arxiv `v2`, PMC author manuscripts replaced by final versions, and
PubMed abstract corrections all produce new versions.

### 2.3 Version record (DynamoDB `articles`)

```json
{
  "pk": "art_01J9...", "sk": 3,
  "status": "current | superseded | retracted | withdrawn | failed",
  "content_hash": "sha256:...", "meta_hash": "sha256:...",
  "source": "pmc", "source_ids": {"pmid": "38012345", "doi": "10.1000/xyz"},
  "normalized_s3": "s3://minerva-normalized/art_01J9.../3/document.json",
  "chunking_version": "chunk-v2", "embedding_model": "amazon.titan-embed-text-v2:0",
  "extraction_prompt_version": "extract-v4", "schema_version": "ex-v2",
  "valid_from": "2025-11-01T03:12:00Z", "valid_to": null,
  "chunk_count": 41, "reused_chunks": 37, "created_at": "...", "pipeline_run_id": "..."
}
```

### 2.4 Chunk identity and reuse

`chunk_hash = sha256(chunking_version + section_heading + normalized_text)`. Table
`chunks_hash` maps `chunk_hash → {embedding_s3_ptr, embedding_model, extraction_ptr}`.
When a new article version is chunked, each chunk hash is looked up; hits reuse the
stored embedding and extraction results. Measured on PubMed corrections and arXiv v2
updates, typically 80–95 % of chunks are unchanged, so refresh cost scales with the
delta, not the article.

## 3. Pipeline (Step Functions)

```
EventBridge (daily 02:00 UTC per source) ──▶ FetchDelta (Lambda)
   │  writes raw to S3, enqueues {source, source_id, raw_s3} to SQS ingest-queue
   ▼
Map state (max concurrency 50) over queue batches:
   Parse (Fargate: GROBID for PDF, JATS/arXiv XML parsers)  → normalized JSON
   Version (Lambda): resolve article_id, compute hashes, decide action
       ├─ unchanged → update last_seen, stop
       ├─ meta_only → SET Paper properties, stop
       ├─ new|changed → create version N+1 (status=pending), continue
       └─ retracted  → mark current version retracted=true, close valid_to, stop
   Chunk (Lambda)        → chunk list with hashes; lookup reuse
   Embed (Lambda)        → Titan V2 for missing hashes only (batch 25)
   Extract (Fargate)     → Claude Sonnet 5.5 structured extraction for missing hashes only
   Link (Lambda)         → ontology normalization
   Upsert (Lambda)       → single Neo4j transaction: write version N+1, flip is_current
   Verify (Lambda)       → counts, orphan check, mark status=current; emit metrics
   on failure → status=failed, DLQ, alarm; version N stays current
```

Idempotency: every stage keys on `(article_id, version, stage)` in DynamoDB
`pipeline_steps`; re-running a failed execution skips completed stages.

### 3.1 Source delta strategies

| Source | Delta mechanism |
|--------|-----------------|
| PubMed | `esearch` with `datetype=mdat&mindate=<last_run-1d>` (modification date catches corrections); 10 k ids per page |
| PMC OA | Compare daily `oa_file_list.csv` / S3 inventory with registry by PMCID + `last_updated` |
| arXiv | OAI-PMH `from=<last_run>` (`ListRecords`, `metadataPrefix=arXiv`); new versions appear as updated records |
| bioRxiv/medRxiv | `/details/{server}/{from}/{to}` paginated; `version` field in payload |
| Retractions | PubMed `"retracted publication"[pt]` daily + Retraction Watch CSV; match by DOI/PMID |
| Curated datasets | S3 `ObjectCreated` on `s3://minerva-curated/` with manifest validation |

### 3.2 Chunking (`chunk-v2`)

- Section-aware: never crosses section boundaries; headings prepended to chunk text.
- Target 512 tokens, max 640, overlap 64 (sentence-aligned). Abstract is always its own chunk.
- Tables and figure captions become their own chunks with `section=figure|table`.
- References are not chunked; they are parsed into `CITES` edges.

### 3.3 Extraction (`extract-v4`)

- Model `anthropic.claude-sonnet-5-5`, strict structured output against
  `specs/extraction-schemas.json`; one call per chunk group (≤ 6 k tokens of input).
- Output per relation: `subject`, `predicate`, `object`, `evidence` (verbatim span),
  `chunk_id`, `confidence` (0–1), `negated` (bool), `hedged` (bool).
- Graph writes keep relations with `confidence ≥ 0.6`; retrieval uses `≥ 0.7`.
- Throughput: online calls at 20 concurrent workers ≈ 4 k articles/h; backfills and
  re-extraction use Bedrock batch inference jobs (JSONL in S3, output to S3) at lower cost.

## 4. Graph write protocol (atomic version flip)

```cypher
// one transaction per article version
MERGE (p:Paper {article_id: $id, version: $v})
SET p += $paperProps, p.is_current = false, p.valid_from = $now
WITH p
UNWIND $chunks AS ch
  MERGE (c:Chunk {chunk_id: ch.chunk_id})
  SET c += ch.props, c.is_current = false, c.valid_from = $now
  MERGE (p)-[:HAS_CHUNK]->(c)
WITH p
UNWIND $mentions AS m
  MERGE (e:Entity {id: m.entity_id})
  MERGE (p)-[r:MENTIONS]->(e) SET r.count = m.count, r.chunk_ids = m.chunk_ids
WITH p
UNWIND $relations AS rel
  MATCH (a:Entity {id: rel.subject}), (b:Entity {id: rel.object})
  MERGE (a)-[r:REL {predicate: rel.predicate, article_id: $id, version: $v}]->(b)
  SET r.confidence = rel.confidence, r.evidence_chunk_ids = rel.evidence_chunk_ids
// flip: previous version → superseded
WITH p
OPTIONAL MATCH (prev:Paper {article_id: $id, is_current: true}) WHERE prev.version < $v
SET prev.is_current = false, prev.valid_to = $now
WITH p, prev
OPTIONAL MATCH (prev)-[:HAS_CHUNK]->(oc:Chunk) SET oc.is_current = false, oc.valid_to = $now
WITH p, prev
FOREACH (_ IN CASE WHEN prev IS NULL THEN [] ELSE [1] END | MERGE (p)-[:SUPERSEDES]->(prev))
SET p.is_current = true
MATCH (p)-[:HAS_CHUNK]->(c) SET c.is_current = true
```

Chunks reused across versions (same `chunk_hash`) are shared nodes: `HAS_CHUNK` from both
versions, `is_current` stays true as long as any current version owns them (the flip step
recomputes `is_current` from ownership). Relation edges are versioned by
`(article_id, version)`; the retrieval query joins to the current paper version, so
superseded evidence disappears from default answers automatically.

## 5. Retraction, correction and deletion semantics

| Event | Effect |
|-------|--------|
| Retraction notice | `Paper.retracted = true` on all versions, `retraction_notice_id` set. Default retrieval filter excludes; UI shows badge when included. Relations from the paper get `retracted = true` and are excluded from graph expansion |
| Correction / erratum | New version via content hash; `SUPERSEDES` chain; erratum text linked as `CORRECTED_BY` |
| Source removal (e.g., withdrawn preprint) | `status = withdrawn`, `valid_to` set, no new version; still queryable with `as_of` |
| GDPR/legal takedown of curated data | Hard delete of chunks and embeddings, tombstone in registry; audit log entry |

## 6. Embedding-model and prompt upgrades (blue/green)

- Embeddings are namespaced by model: a second vector index `chunk_embedding_v2` is built
  in the background by a Step Functions backfill reading `chunks_hash`.
- The retriever reads the index named in SSM `/minerva/retrieval/vector_index`; flipping
  the parameter switches traffic; the old index is dropped after a 7-day soak.
- Extraction prompt/schema upgrades re-run only on a sampled 2 % first; if the eval in
  doc 05 §2.3 passes, a full re-extraction batch job runs, writing relations with the new
  `extraction_prompt_version` and the flip removes the old ones per article.
- Chunking-version changes invalidate all chunk hashes by construction (`chunk-vN` is in
  the hash input) and therefore trigger a controlled full rebuild on a clone of the
  database that is promoted via DNS/parameter switch.

## 7. Refresh economics (1 M-article corpus, steady state)

| Daily input | Count | Work |
|-------------|-------|------|
| New articles | ~3 000 | Full pipeline |
| Changed articles (content) | ~800 | ~15 % of chunks re-embedded and re-extracted |
| Meta-only changes | ~20 000 | Property updates only |
| Retractions | ~5–10 | Flag updates |
| Compute | — | ~1.5 h wall-clock at concurrency 50; ~$75/day Bedrock |

Compared with naive "re-ingest everything that was modified": ~6× fewer embedding calls and
~5× fewer extraction calls, because chunk-hash reuse skips unchanged text.

## 8. Operational controls

- **Freshness SLO**: 95 % of source updates visible within 24 h; metric
  `ingest_lag_hours` per source.
- **Backpressure**: SQS depth > 50 k → pipeline scales Map concurrency to 100; Bedrock
  throttling → exponential backoff with jitter; extraction switches to batch mode when
  backlog > 12 h.
- **Quality gates**: a pipeline run is auto-rolled back (versions stay `pending`) if
  parse-failure rate > 5 %, extraction schema-failure rate > 1 %, or entity-link rate drops
  > 15 % versus the trailing 7-day mean.
- **Rebuild drill**: quarterly restore of Neo4j from S3 normalized store on a clone; must
  complete in < 12 h and match current counts within 0.1 %.
