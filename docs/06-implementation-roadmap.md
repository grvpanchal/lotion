# 06 — Implementation Roadmap

| Phase | Duration | Scope | Exit criteria |
|-------|----------|-------|---------------|
| 0. Foundations | 2 weeks | CDK stacks (network, EC2, Neo4j, DynamoDB, S3, IAM), Cognito, CI, observability skeleton | Infra deploys from scratch in < 45 min; `/healthz` green behind Route 53; Session Manager access only |
| 1. Ingestion MVP | 4 weeks | PubMed + PMC OA fetch, parse, versioning, chunking, embeddings, Neo4j upsert; registry; 100 k-article backfill | Freshness SLO met on staging; chunk reuse ≥ 80 % on corrections; rebuild drill passes |
| 2. Chat MVP | 4 weeks | Query understanding, hybrid retrieval + RRF, rerank, citations, SSE UI, sessions, feedback, guardrails | `retrieval-gold` and `answer-gold` gates pass (doc 05 §2.1–2.2 with hybrid only); p95 TTFT ≤ 2.5 s |
| 3. Knowledge graph | 5 weeks | Entity/relation extraction with strict schemas, ontology linking, graph expansion in retrieval, graph UI, batch inference path | Extraction gates (§2.3) pass; relationship answerable rate ≥ 0.75; expansion adds ≤ 150 ms |
| 4. Hardening & scale | 3 weeks | arXiv/bioRxiv/curated sources, retraction feed, blue/green embedding upgrade, canary release process, load test, cost dashboard | 1 M articles ingested; load test passes; canary pipeline exercised once end-to-end |
| 5. Optional | — | OpenSearch split, Neo4j HA/Neptune, community summaries for "overview" intent, institutional SAML | Triggered by signals in doc 01 §8 |

Team shape: 1 backend (Python), 1 data/pipeline, 1 frontend, 0.5 DevOps, 0.5 domain
curator for golden sets (curator effort front-loaded in phases 1–2).

Risks and mitigations:

| Risk | Mitigation |
|------|------------|
| Extraction cost of backfill | Abstract-only extraction first; full text for OA top-cited; batch inference |
| Golden set quality | Double annotation, κ check, monthly growth from production |
| Neo4j single-instance limits | Scale triggers defined; interface isolation (`Retriever`, `GraphExpander`) |
| Bedrock quota | Request quota increases in phase 0; provisioned throughput for chat model if needed |
