# MINERVA — Graph-RAG Research Discovery Platform on AWS

Architecture and technical specifications for a knowledge-discovery platform that lets
researchers chat with a continuously refreshed corpus of scientific publications. The
system integrates **AWS AI (Amazon Bedrock), compute (EC2), and networking (Route 53 / ALB)**
into one platform, with a graph database at the center of a **hybrid Graph-RAG** retrieval
pipeline.

This repository is documentation-first: it contains the design, contracts, and schemas
needed to implement the platform. No application code lives here yet.

## Document map

| # | Document | What it answers |
|---|----------|-----------------|
| 1 | [docs/01-system-architecture.md](docs/01-system-architecture.md) | What runs where on AWS, how components talk, security, scaling, cost |
| 2 | [docs/02-chat-retrieval-tech-spec.md](docs/02-chat-retrieval-tech-spec.md) | Full technical spec for the chat: API, retrieval pipeline, prompts, data model, streaming, auth |
| 3 | [docs/03-rag-architecture-justification.md](docs/03-rag-architecture-justification.md) | Why hybrid Graph-RAG (lexical + vector + graph expansion + rerank), with alternatives rejected |
| 4 | [docs/04-ingestion-versioning-refresh.md](docs/04-ingestion-versioning-refresh.md) | Ingestion pipeline and article versioning so the index refreshes incrementally, safely, and cheaply |
| 5 | [docs/05-evals-guardrails-thresholds.md](docs/05-evals-guardrails-thresholds.md) | Offline/online evals, guardrails, numeric release thresholds, and alerting |
| 6 | [docs/06-implementation-roadmap.md](docs/06-implementation-roadmap.md) | Phased delivery plan with exit criteria per phase |

Machine-readable contracts:

| File | Purpose |
|------|---------|
| [specs/openapi.yaml](specs/openapi.yaml) | REST + SSE contract for the chat/search API |
| [specs/graph-schema.cypher](specs/graph-schema.cypher) | Neo4j node/relationship schema, constraints, vector + full-text indexes |
| [specs/chunk-index-mapping.json](specs/chunk-index-mapping.json) | OpenSearch mapping for the scale-out path (phase 3) |
| [specs/extraction-schemas.json](specs/extraction-schemas.json) | JSON Schemas enforced on Claude structured outputs for entity/relation extraction |
| [specs/prompts.md](specs/prompts.md) | System prompts and prompt-assembly rules for every LLM call |
| [infra/cdk-outline.md](infra/cdk-outline.md) | AWS CDK stack layout, IAM, networking, parameters |

## One-paragraph summary

Users reach the web application through Route 53 → ALB → an EC2 Auto Scaling group that
hosts the chat UI, API, and metrics dashboards. Scientific publications, public repositories,
and curated datasets land in S3 and flow through a Step Functions ingestion pipeline that
parses, chunks, embeds (Bedrock Titan Embeddings V2), and extracts entities and relations
(Claude on Bedrock with strict structured outputs) into a **Neo4j** graph that also holds
vector and full-text indexes. A chat query is rewritten and entity-linked, retrieved by
**hybrid BM25 + vector search fused with reciprocal rank fusion**, **expanded through the graph**
(citations, shared entities, same-cohort papers), **reranked** with Bedrock Rerank, and
answered by Claude with **document citations** so every claim points to a specific paper
passage. Every article is **content-hash versioned**; refreshes re-embed and re-extract only
changed chunks, keep prior versions queryable for audit, and retire superseded or retracted
work from retrieval without downtime.

## Key technology choices (summary)

| Concern | Choice | Alternative kept as scale-out path |
|---------|--------|-----------------------------------|
| LLM (answering, query understanding) | Claude Opus 5.5 on Amazon Bedrock (`anthropic.claude-opus-5-5`) | Claude Sonnet 5.5 for bulk extraction and LLM-judge evals |
| Embeddings | Amazon Titan Text Embeddings V2 (1024-d) on Bedrock | Cohere Embed v4 on Bedrock |
| Reranker | Amazon Bedrock Rerank (Cohere Rerank 3.5) | Cross-encoder on SageMaker |
| Graph + vector + lexical store (phase 1–2) | Neo4j 5.x on EC2 (single store, matches target diagram) | Amazon Neptune (graph) + OpenSearch (hybrid) at >5M chunks |
| Ingestion orchestration | EventBridge → Step Functions → Lambda / ECS Fargate | — |
| PDF parsing | GROBID on ECS Fargate; PMC/arXiv XML preferred when available | Amazon Textract for scanned PDFs |
| Registry / versions / sessions | DynamoDB | — |
| Auth | Amazon Cognito (OIDC, SAML federation for institutions) | — |
| Safety | Amazon Bedrock Guardrails + application-level checks | — |
| Observability | CloudWatch, X-Ray, OpenTelemetry; in-app metrics dashboard | — |

## Conventions

- All prompts, schemas and thresholds are versioned in this repo; a change to any of them
  is a release and must pass the gates in `docs/05-evals-guardrails-thresholds.md`.
- Retrieved paper text is always treated as **data, never as instructions** (see prompts).
- Nothing in retrieval may read a non-current article version unless the request explicitly
  asks for history (`as_of` parameter).
