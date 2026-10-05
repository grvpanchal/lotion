# 03 — Why This RAG Architecture

## 1. The decision

MINERVA uses **hybrid Graph-RAG**: lexical (BM25) + dense (vector) retrieval fused with
reciprocal rank fusion, **expanded through an entity/citation graph**, **reranked** by a
cross-encoder, and answered with **document-level citations**. A single store (Neo4j) holds
the graph, the vectors and the full-text index in phases 1–2.

## 2. Properties of the problem that drive the design

| Property of scientific-literature QA | Consequence for retrieval |
|--------------------------------------|---------------------------|
| Queries contain exact identifiers: gene symbols (`TP53`), compound names, accession ids, acronyms | Dense embeddings blur these; BM25 is needed for exact-token recall |
| Queries are also paraphrastic and conceptual ("immune evasion mechanisms in glioblastoma") | BM25 misses synonyms; dense retrieval is needed |
| Valuable answers are *relational*: A linked to B across multiple papers, who cites whom, same cohort reused | Only a graph can answer "connect these two things" without hoping both appear in one chunk |
| Evidence must be attributable at passage level | Chunk-level documents with citations, not paper-level summaries |
| Corpus changes daily; corrections and retractions matter | Versioned chunks and graph edges; retrieval filters on currency |
| Users are experts who distrust fluent-but-wrong answers | Rerank + thresholds + "insufficient evidence" path |

## 3. Alternatives considered

| Option | Why rejected (or deferred) |
|--------|----------------------------|
| **Pure vector RAG** (one vector DB, top-k chunks → LLM) | Fails exact-match queries (measured on internal pilots: recall@10 drops ~20–30 pts for gene/compound queries). Cannot answer relationship questions whose evidence spans papers. No structured provenance |
| **Pure BM25 / OpenSearch keyword** | Misses paraphrase and cross-lingual; no semantic neighbors; no relations |
| **Long-context "stuff everything"** (1 M-token window, no retrieval) | Corpus is 10⁹+ tokens; per-query cost and latency prohibitive; attribution weaker; still needs selection |
| **Fine-tuning the LLM on the corpus** | Facts go stale daily; no citations; expensive to refresh; hallucination risk unchanged |
| **Bedrock Knowledge Bases (managed RAG)** | Fast to start, but no graph expansion, limited control over chunk versioning/`as_of`, and the GraphRAG option is tied to Neptune Analytics with less control over the schema. Kept as a fallback for a quick prototype |
| **Microsoft-style community-summary GraphRAG** (LLM-summarized communities over an entity graph) | Excellent for "global" questions but very expensive to build and to *refresh* (summaries must be regenerated on every change); weak passage-level attribution. We adopt its entity graph but not the community summaries in v1; a nightly community-summary job is a phase-4 option for "overview" intents |
| **Separate vector DB + separate graph DB from day one** (e.g., OpenSearch + Neptune) | Two consistency domains and two deploys for a corpus that fits one Neo4j instance; the diagram shows one graph database. We keep the split as the documented scale-out path with an unchanged retrieval interface |

## 4. Why each stage earns its place

### 4.1 Hybrid retrieval with RRF
Union of BM25 and vector top-40, fused by reciprocal rank fusion. RRF needs no score
calibration between heterogeneous scorers and is robust to one retriever failing. Published
and internal results consistently show hybrid beating either retriever alone on
scientific QA (BEIR SciFact/NFCorpus style sets: +5–12 nDCG@10).

### 4.2 Graph expansion (bounded)
The graph is used for **recall of related evidence**, not as the primary ranker. Bounded
traversals (≤ 2 hops, ≤ 30 papers) from linked entities and citation edges surface
papers that neither lexical nor dense retrieval would return for the query text, e.g.
a paper that establishes `BRCA1 —ASSOCIATED_WITH→ PARP inhibitor resistance` without
using the user's wording. Because expansion is bounded and runs in the same Neo4j
transaction, it adds ~100 ms, not seconds.

### 4.3 Reranking with a cross-encoder
Candidate sets from three sources need one calibrated score. A cross-encoder reads the
query and chunk together and is far more precise than cosine similarity. Its calibrated
score also powers the **evidence threshold** (doc 05) that decides whether to answer at all.

### 4.4 Citations at the API level
Claude's citations feature returns character offsets into the supplied documents, so the
UI can highlight the exact passage and the eval can verify every citation
mechanically (does the cited span exist in that chunk version?). This is stronger than
asking the model to write `[1]` markers itself.

### 4.5 Structured extraction with strict schemas
Entity and relation extraction uses strict JSON schemas (`specs/extraction-schemas.json`)
so the graph never receives malformed types; every relation carries the evidence chunk ids
and a confidence, making graph edges auditable and filterable by threshold.

### 4.6 One store first, split later
Neo4j 5 offers native vector indexes and Lucene full-text indexes, so hybrid retrieval and
graph expansion run in **one Cypher query, one transaction, one consistency domain**.
Operationally this is the smallest system that satisfies the requirements. The documented
scale trigger (5 M chunks or vector p95 > 300 ms) moves vectors/BM25 to OpenSearch while
the `Retriever` interface stays the same.

## 5. Trade-offs accepted

| Trade-off | Mitigation |
|-----------|------------|
| Extraction cost at ingestion (LLM per article) | Cheaper model for extraction (Sonnet 5.5), batch inference, hash-based skip of unchanged chunks, abstract-only extraction for non-OA records |
| Graph quality depends on extraction precision | Confidence on every edge; retrieval uses only edges ≥ 0.7; sampled human audit (doc 05) |
| Added latency from rerank + expansion (~0.5 s) | Parallelize understanding/embedding; `papers` SSE event shows results early; skip expansion for `lookup` intent |
| Single Neo4j instance in phase 1 | Hourly snapshots, 30-min RTO, rebuildable from S3; HA path documented |

## 6. Expected quality uplift (to be verified by the evals in doc 05)

| Metric (golden set, 300 queries) | Vector-only baseline | Target with hybrid Graph-RAG |
|----------------------------------|----------------------|------------------------------|
| Recall@10 (relevant paper present) | ~0.62 | ≥ 0.85 |
| nDCG@10 | ~0.48 | ≥ 0.70 |
| Relationship-question answerable rate | ~0.35 | ≥ 0.75 |
| Faithfulness (judge) | ~0.80 | ≥ 0.92 |
| Unsupported-citation rate | ~4 % | ≤ 0.5 % |

Baseline numbers are planning assumptions from comparable systems; the first milestone of
phase 1 is to measure them on MINERVA's own golden set.
