# 01 — System Architecture on AWS

## 1. Goals and non-goals

**Goals**

- Let researchers ask natural-language questions and receive grounded answers with citations
  to specific passages in scientific publications.
- Discover *relationships* a flat search cannot: papers that share a cohort, a gene–disease
  link established across several studies, methods that cite one another.
- Keep the corpus fresh: new publications and corrections appear within 24 h; retractions are
  reflected within 24 h.
- Run on AWS-managed services where practical, with one clear scale-out path per component.

**Non-goals (v1)**

- Clinical decision support or patient-specific advice. The system is a literature tool.
- Full-text ingestion of paywalled content; v1 ingests open-access full text and
  abstract-only records for the rest.
- Multi-tenant isolation between institutions (single-tenant deployment per institution).

## 2. Reference diagram (logical)

```
                         ┌──────────────────────────────────────────────────────────────┐
                         │ AWS Cloud (single region, 2 AZs)                             │
                         │                                                              │
  MINERVA users ───HTTPS─┼─▶ Route 53 ─▶ ALB (WAF) ─▶ EC2 Auto Scaling group            │
                         │                              ├─ Web UI (Next.js)             │
                         │                              ├─ API (FastAPI) — chat, search │
                         │                              ├─ Credentials (Cognito client) │
                         │                              └─ Metrics / data visualization │
                         │                                        │                     │
                         │                                        │ Bolt (TLS)          │
                         │                                        ▼                     │
                         │                              Neo4j 5.x (EC2, EBS gp3)        │
                         │                              graph + vector + full-text      │
                         │                                        ▲                     │
                         │          ┌─────────────────────────────┘ upserts             │
                         │          │                                                   │
                         │  Data Sources (S3 landing)        Amazon Bedrock             │
                         │  ├─ Scientific publications ─┐    ├─ Claude Opus 5.5 (chat) │
                         │  ├─ Public repositories ─────┼─▶  ├─ Claude Sonnet 5.5      │
                         │  └─ Curated datasets ────────┘    │   (bulk extraction)      │
                         │          │                        ├─ Titan Embeddings V2     │
                         │          ▼                        ├─ Rerank                  │
                         │  Step Functions ingestion         └─ Guardrails              │
                         │  (Lambda + ECS Fargate workers)                               │
                         │  Knowledge processing: entity extraction → relation           │
                         │  extraction → graph construction                              │
                         │                                                              │
                         │  DynamoDB (article registry, versions, sessions)             │
                         │  CloudWatch / X-Ray / Secrets Manager / KMS                  │
                         └──────────────────────────────────────────────────────────────┘
```

The target diagram shows a single EC2 instance holding the web application and the graph
database. This design keeps that shape for phase 1 (one instance, two processes) and splits
the application tier and the database tier in phase 2 (see §8) without changing any interface.

## 3. Component inventory

### 3.1 Networking and edge

| Component | Configuration | Rationale |
|-----------|---------------|-----------|
| Route 53 | Public hosted zone, `A`/`AAAA` alias to ALB, health check on `/healthz` | Managed DNS, failover-ready |
| ACM | TLS certificate for `minerva.<domain>` | Free managed certs, auto-renewal |
| Application Load Balancer | HTTPS 443 only, HTTP→HTTPS redirect, idle timeout 300 s (SSE streams) | Terminates TLS, sticky sessions not required (stateless API) |
| AWS WAF | AWS managed rule groups (Core, Known Bad Inputs), rate limit 300 req / 5 min / IP | Blocks scanners and abuse before the app |
| VPC | 2 AZs, public subnets (ALB, NAT), private subnets (EC2, Neo4j, Fargate) | No instance has a public IP |
| VPC endpoints | S3 (gateway), Bedrock Runtime, DynamoDB, Secrets Manager, CloudWatch Logs, ECR | Bedrock traffic never leaves the AWS network |

### 3.2 Application tier (EC2)

| Item | Value |
|------|-------|
| Instance | `m7i.xlarge` (4 vCPU / 16 GiB) in an Auto Scaling group, min 1 / desired 2 / max 6 |
| AMI | Amazon Linux 2023, hardened via SSM; no SSH, Session Manager only |
| Runtime | Docker Compose on instance (phase 1) → ECS on EC2 (phase 2) |
| Processes | `web` (Next.js 15, static + SSR), `api` (Python 3.12, FastAPI, uvicorn workers = 2×vCPU) |
| Config | SSM Parameter Store (non-secret), Secrets Manager (Neo4j password, OAuth client secret) |
| Credentials | IAM instance role with least-privilege policies (see `infra/cdk-outline.md`) |
| Scaling signal | ALB `RequestCountPerTarget` > 50 or CPU > 60 % for 3 min |
| Health | `/healthz` (process), `/readyz` (Neo4j reachable + Bedrock `ListFoundationModels` cached OK) |

"Credentials" in the diagram = the Cognito-backed login (OIDC with institutional SAML
federation) plus API-key issuance for programmatic users. "Metrics, Data visualization" =
an in-app dashboard reading CloudWatch Metrics via the API (query volume, latency, retrieval
quality, corpus growth) and graph visualizations of retrieved neighborhoods.

### 3.3 Graph database (Neo4j 5.x)

| Item | Value |
|------|-------|
| Edition | Neo4j Community for ≤ 1 instance; Enterprise (causal cluster, 3 cores) if HA required |
| Instance | `r7i.2xlarge` (8 vCPU / 64 GiB), page cache 32 GiB, heap 16 GiB |
| Storage | EBS gp3, 1 TiB, 6 000 IOPS, 250 MiB/s; daily EBS snapshots (35-day retention) + weekly `neo4j-admin database dump` to S3 |
| Indexes | Vector index on `Chunk.embedding` (1024-d, cosine); full-text (Lucene) index on `Chunk.text`, `Paper.title`, `Paper.abstract`; range indexes on ids, dates, `is_current` |
| Why one store | Graph traversal, vector k-NN and BM25 in a single Cypher query; one consistency domain; matches the target diagram. Scale trigger in §8 |
| Access | Bolt over TLS from the app security group only; credentials rotated by Secrets Manager |

Schema and index DDL: `specs/graph-schema.cypher`.

### 3.4 Amazon Bedrock

| Capability | Model / feature | Used for |
|------------|-----------------|----------|
| Chat answering | Claude Opus 5.5 (`anthropic.claude-opus-5-5`), adaptive thinking, effort `medium` for chat, streaming, document citations | Final grounded answer |
| Query understanding | Claude Opus 5.5, effort `low`, structured outputs | Rewrite, intent, entity linking, filters |
| Bulk extraction | Claude Sonnet 5.5 (`anthropic.claude-sonnet-5-5`), structured outputs with strict schema | Entity + relation extraction at ingestion |
| LLM judge (evals) | Claude Sonnet 5.5 | Faithfulness, relevance grading |
| Embeddings | Amazon Titan Text Embeddings V2, 1024-d, normalized | Chunk and query embeddings |
| Rerank | Bedrock Rerank API (Cohere Rerank 3.5) | Top-50 → top-8 context selection |
| Guardrails | Bedrock Guardrails: denied topics (medical advice to individuals), PII masking on input, prompt-attack filter | Input and output filtering |
| Prompt caching | Explicit `cache_control` breakpoints on system prompt and tool definitions | ~90 % input-cost reduction on stable prefix |

Client library: Anthropic SDK Bedrock Mantle client (`AnthropicBedrockMantle` in Python)
so the application speaks the Messages API and can move between Bedrock and the first-party
API without code changes. Model IDs on Bedrock carry the `anthropic.` prefix. Message
Batches is not available on Bedrock; bulk extraction uses Bedrock batch inference jobs or
rate-limited online calls (see doc 04).

### 3.5 Data sources and landing

| Source | Access method | Format | Cadence |
|--------|---------------|--------|---------|
| PubMed / MEDLINE | E-utilities (`esearch` with `mdat` window, `efetch`) | XML | Daily incremental |
| PubMed Central OA subset | AWS Open Data S3 bucket (`pmc-oa-opendata`) | JATS XML, PDF | Daily manifest diff |
| arXiv | OAI-PMH + Kaggle metadata snapshot; PDFs from arXiv S3 requester-pays bucket | JSON, PDF | Daily |
| bioRxiv / medRxiv | REST API (`/details/{server}/{from}/{to}`) | JSON, PDF | Daily |
| Public repositories (GEO, ClinicalTrials.gov, UniProt, ChEMBL) | Bulk downloads + APIs | Mixed | Weekly |
| Curated datasets (internal) | S3 upload with manifest, validated by Lambda | CSV/Parquet/PDF | On demand |
| Retractions | PubMed `retracted publication[pt]` + Retraction Watch feed | XML/CSV | Daily |

All raw payloads land in `s3://minerva-raw/<source>/<yyyy>/<mm>/<dd>/` with versioning
enabled and Object Lock (governance) for provenance. Normalized documents are written to
`s3://minerva-normalized/<article_id>/<version>/document.json`.

### 3.6 Knowledge processing pipeline

Orchestrated by Step Functions (Standard workflow), triggered by EventBridge schedules
and S3 event notifications. Stages (details in doc 04):

1. **Fetch** (Lambda): pull deltas, write raw to S3, enqueue article ids on SQS.
2. **Parse** (ECS Fargate, GROBID + custom JATS parser): produce normalized document JSON
   (title, abstract, sections, references, figures captions, metadata).
3. **Version** (Lambda): compute content hash, compare with DynamoDB registry, decide
   `new | changed | unchanged | retracted`.
4. **Chunk** (Lambda): section-aware chunking, 512-token target, 64-token overlap,
   per-chunk content hash.
5. **Embed** (Lambda, batched 25 chunks/call): Titan V2; skip chunks whose hash exists.
6. **Extract** (ECS Fargate workers calling Claude Sonnet 5.5 with strict schemas):
   entities (Gene, Protein, Disease, Chemical, Method, Dataset, Organism, Cohort),
   relations (TREATS, ASSOCIATED_WITH, INHIBITS, USES_METHOD, EVALUATED_ON, …) with
   evidence span and confidence.
7. **Link** (Lambda): normalize entities to ontologies (MeSH, UMLS, HGNC, ChEBI) via
   exact + embedding match; unresolved entities stay as `candidate` nodes.
8. **Construct graph** (Lambda → Neo4j): idempotent `MERGE` upserts in one transaction per
   article version; flip `is_current`.
9. **Verify** (Lambda): post-write checks (counts, orphan nodes, index health) and
   emit metrics.

### 3.7 State and metadata (DynamoDB)

| Table | Key | Purpose |
|-------|-----|---------|
| `articles` | `pk=article_id`, `sk=version` | Registry of every version: content hash, source, status, timestamps, embedding model version |
| `chunks_hash` | `pk=chunk_hash` | Dedup of embeddings across versions and articles |
| `sessions` | `pk=user_id`, `sk=session_id` | Chat sessions, TTL 90 days |
| `messages` | `pk=session_id`, `sk=ts` | Conversation turns incl. retrieved context ids for audit |
| `feedback` | `pk=message_id` | Thumbs, corrections, flagged citations |

### 3.8 Observability

- **Metrics**: CloudWatch EMF from API (latency per stage, tokens, cache hit rate,
  retrieval scores) and from pipeline (docs/day, failures, extraction confidence).
- **Traces**: X-Ray / OpenTelemetry spans for every chat turn: `understand → retrieve →
  expand → rerank → generate`.
- **Logs**: Structured JSON to CloudWatch Logs; retrieved chunk ids and prompt hashes
  logged (not raw user PII); 1-year retention.
- **Dashboards**: CloudWatch dashboard + in-app metrics page (the "Metrics, Data
  visualization" box in the diagram).
- **Alarms**: see doc 05 §6.

## 4. Request flow — one chat turn

```
1. Browser → ALB → API  POST /v1/chat/sessions/{id}/messages   (SSE response)
2. API: auth (Cognito JWT) → rate limit (DynamoDB token bucket) → Bedrock Guardrails (input)
3. Query understanding (Claude, effort low, structured output):
     { rewritten_query, intent, entities[], filters{year_from, year_to, organism, study_type} }
4. Retrieval in Neo4j (single Cypher):
     a. vector k-NN on Chunk.embedding  (k=40)
     b. BM25 full-text on Chunk.text     (k=40)
     c. RRF fusion → top 40 chunks → their Papers
5. Graph expansion (bounded, ≤ 2 hops, ≤ 30 extra papers):
     linked entities → papers with the same entity pair; CITES/CITED_BY; SAME_COHORT
6. Rerank (Bedrock Rerank) over ≤ 70 candidate chunks → top 8 (threshold-gated)
7. Context assembly: document blocks with citations enabled, dedup per paper, ≤ 12k tokens
8. Generation (Claude Opus 5.5, streaming, citations) → SSE events: token, citation, done
9. Bedrock Guardrails (output) → persist message + context ids → metrics
```

Latency budget (p95): understand 900 ms · retrieve 250 ms · expand 150 ms · rerank 400 ms ·
first token 1.2 s · full answer 8 s.

## 5. Security

- **Identity**: Cognito user pool, MFA optional, SAML federation to institutional IdP.
  Short-lived JWT (1 h) + refresh (30 d). API keys for service accounts, hashed at rest.
- **Authorization**: role claims (`reader`, `curator`, `admin`). Curators can trigger
  re-ingestion and mark retractions; admins manage keys and thresholds.
- **Data**: all buckets and EBS volumes encrypted with KMS CMKs; Neo4j at-rest encryption
  via EBS; TLS 1.2+ everywhere; Bedrock does not retain prompts for training.
- **Network**: private subnets, VPC endpoints, security groups allow only
  ALB→app:8080 and app→Neo4j:7687.
- **Prompt injection**: retrieved text is placed only in `document` content blocks and
  framed as data; system prompt forbids following instructions inside documents;
  Guardrails prompt-attack filter on user input; eval in doc 05 §4.
- **Secrets**: Secrets Manager with 30-day rotation for the Neo4j user; no secrets in env
  files or images.
- **Audit**: CloudTrail (management + Bedrock data events), every answer stores the exact
  chunk ids and prompt/version hashes used.

## 6. Availability and recovery

| Aspect | Phase 1 | Phase 2+ |
|--------|---------|----------|
| App tier | ASG across 2 AZs | Same, behind ECS |
| Graph DB | Single instance, EBS snapshots hourly, RPO 1 h, RTO 30 min (restore from snapshot + replay from S3 normalized store) | Neo4j Enterprise causal cluster or Neptune, RPO ~0 |
| Pipeline | Idempotent stages; Step Functions retries with backoff; DLQ on SQS | Same |
| Rebuild from scratch | Possible from `minerva-normalized` + DynamoDB registry; estimated 12 h for 1 M articles with batch inference | Same |

## 7. Cost model (illustrative, us-east-1, 1 M articles, 50 k chat turns/month)

| Line | Monthly estimate |
|------|------------------|
| EC2 app (2 × m7i.xlarge) | ~$300 |
| EC2 Neo4j (r7i.2xlarge + 1 TiB gp3) | ~$520 |
| ALB + WAF + Route 53 + NAT | ~$90 |
| Bedrock chat (Opus 5.5, ~9 k input / 700 output tokens per turn, 85 % cached prefix) | ~$1 600 |
| Bedrock embeddings (incremental ~60 k new chunks/day) | ~$40 |
| Bedrock extraction (Sonnet 5.5, ~3 k new/changed articles/day) | ~$900 |
| Rerank | ~$60 |
| Step Functions, Lambda, Fargate, DynamoDB, S3 | ~$250 |
| **Total** | **~$3 800** |

Bedrock prices differ from first-party Anthropic prices; confirm against the Bedrock
pricing page before budgeting. The initial backfill of 1 M articles is a one-time cost
dominated by extraction (~$25 k at online rates; roughly half with batch inference).

## 8. Scaling triggers and migration paths

| Signal | Action |
|--------|--------|
| > 5 M chunks or vector query p95 > 300 ms | Move chunk vectors + BM25 to Amazon OpenSearch (mapping in `specs/chunk-index-mapping.json`); Neo4j keeps graph only. Retrieval interface unchanged |
| Need for HA graph with zero-RPO | Neo4j Enterprise cluster or Amazon Neptune (openCypher); Cypher is kept to the common subset |
| Extraction backlog > 24 h | Switch extraction to Bedrock batch inference; add Fargate workers |
| > 200 concurrent chat users | ASG max 12; move SSE fan-out to ECS; enable Bedrock provisioned throughput |

## 9. Fidelity to the target diagram

| Diagram element | This design |
|-----------------|-------------|
| MINERVA users → Route 53 | Route 53 alias → ALB (added for TLS, WAF, scaling) |
| EC2 instance contents: web app, credentials, metrics/visualization | EC2 ASG running web + API; Cognito login; in-app metrics dashboard |
| Graph Database (inside EC2) | Neo4j on EC2 in the same VPC; phase 1 may co-locate on the same instance |
| Data Sources → Amazon Bedrock | S3 landing → Step Functions → Bedrock models (ingestion) |
| Model → LLM Inference → Knowledge Processing (entity, relation, graph construction) | Claude Sonnet 5.5 structured extraction → linking → Neo4j upsert |
| Graph-RAG (bidirectional Graph DB ↔ Bedrock) | Chat path: retrieval from Neo4j, generation on Bedrock; ingestion path: Bedrock output written to Neo4j |
