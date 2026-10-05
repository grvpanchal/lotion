# Infrastructure outline (AWS CDK v2, TypeScript)

One CDK app, five stacks, deployed per environment (`dev`, `staging`, `prod`) via
GitHub Actions with OIDC role assumption. Stack boundaries follow change frequency.

```
infra/
  bin/minerva.ts                 # app entry: env config → stacks
  lib/network-stack.ts           # VPC, subnets, endpoints, security groups, WAF
  lib/data-stack.ts              # S3 buckets, DynamoDB tables, KMS keys
  lib/graph-stack.ts             # Neo4j EC2, EBS, backups, Secrets Manager
  lib/app-stack.ts               # ASG + launch template, ALB, Route 53, ACM, Cognito
  lib/pipeline-stack.ts          # Step Functions, Lambdas, Fargate tasks, SQS, EventBridge, Guardrails
  lib/observability-stack.ts     # dashboards, alarms, log groups (optional 6th stack)
  config/{dev,staging,prod}.json # sizes, domain, quotas, thresholds (SSM seeds)
```

## NetworkStack

- `Vpc` 2 AZs, `/16`, public (ALB/NAT) + private-with-egress (app, Fargate) + isolated
  (Neo4j) subnets. One NAT per AZ in prod, one total in dev.
- Interface endpoints: `bedrock-runtime`, `secretsmanager`, `logs`, `ecr.api`,
  `ecr.dkr`, `ssm`, `ssmmessages`, `sts`; gateway endpoints: `s3`, `dynamodb`.
- Security groups: `alb-sg` (443 from 0.0.0.0/0), `app-sg` (8080 from `alb-sg`),
  `neo4j-sg` (7687 from `app-sg` and `pipeline-sg`), `pipeline-sg` (egress only).
- WAF WebACL (AWSManagedRulesCommonRuleSet, KnownBadInputs, rate rule 300/5 min) attached
  to the ALB.

## DataStack

- Buckets (KMS, versioned, block public): `minerva-raw` (Object Lock governance, 7-year
  retention), `minerva-normalized`, `minerva-curated`, `minerva-evals`,
  `minerva-backups` (lifecycle to Glacier after 30 d).
- DynamoDB (on-demand, PITR on): `articles` (pk `article_id`, sk `version`; GSI
  `by_source_id` on `source_id`; GSI `by_status` on `status`,`valid_from`), `chunks_hash`,
  `pipeline_steps` (TTL 90 d), `sessions` (TTL 90 d), `messages`, `feedback`, `rate_limits` (TTL).
- KMS CMKs: `minerva-data`, `minerva-logs`.

## GraphStack

- `r7i.2xlarge` in isolated subnet, Amazon Linux 2023, Neo4j 5.x installed by user-data
  from a pinned package; `neo4j.conf` from SSM (page cache 32G, heap 16G, bolt TLS).
- EBS gp3 1 TiB (6 000 IOPS, 250 MiB/s) data volume, separate 100 GiB logs volume.
- Data Lifecycle Manager: hourly snapshots, 48 kept; daily, 35 kept.
- Weekly `neo4j-admin database dump` to `minerva-backups` via SSM Association.
- Secrets Manager secret `minerva/neo4j` with 30-day rotation Lambda.
- Schema applied by a one-off SSM Run Command executing `specs/graph-schema.cypher`.
- Phase-2 option: `enterprise=true` flag deploys 3-node causal cluster behind an NLB.

## AppStack

- Launch template (AL2023, IMDSv2 required, SSM agent, CloudWatch agent, Docker), ASG
  min 1 / desired 2 / max 6 across 2 AZs, target tracking on `ALBRequestCountPerTarget` 50.
- ALB: HTTPS listener (ACM cert for `minerva.<domain>`), HTTP→HTTPS redirect, idle
  timeout 300 s, target group health check `/readyz`, deregistration delay 30 s
  (SSE streams finish within budget).
- Route 53: alias `A`/`AAAA` records; health-checked failover record to a static S3
  maintenance page.
- Cognito user pool (email + SAML federation placeholder), app client with PKCE, hosted
  UI domain; JWT authorizer implemented in the API (ALB OIDC auth optional).
- Instance role policies (least privilege):
  - `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream` on the chat, embedding
    and rerank model ARNs only; `bedrock:ApplyGuardrail` on the Guardrail ARN.
  - `dynamodb:*Item`, `Query` on the app tables; `s3:GetObject` on `minerva-normalized`.
  - `secretsmanager:GetSecretValue` on `minerva/neo4j`; `ssm:GetParameter*` on `/minerva/*`.
  - `cloudwatch:PutMetricData`, `logs:*` on the app log group, `xray:Put*`.
- Deployment: image from ECR pulled by user-data (phase 1) → ECS on EC2 (phase 2).

## PipelineStack

- SQS `ingest-queue` (visibility 15 min, DLQ after 5 receives), `extract-queue`.
- Lambdas (Python 3.12, arm64, 1–3 GiB): `fetch-pubmed`, `fetch-pmc`, `fetch-arxiv`,
  `fetch-biorxiv`, `fetch-retractions`, `version`, `chunk`, `embed`, `link`, `upsert`,
  `verify`, `curated-validate`.
- Fargate task definitions: `grobid` (4 vCPU / 16 GiB, GROBID image), `parse`,
  `extract` (calls Bedrock with concurrency 20), `batch-submit` (Bedrock batch inference).
- Step Functions Standard state machine `ingest` with a Distributed Map (concurrency 50)
  per source; EventBridge schedules at 02:00 UTC staggered by source; S3 event rule for
  `minerva-curated`.
- Bedrock Guardrail resource with the configuration in `specs/prompts.md` §5; model
  access enabled for Claude Opus 5.5, Claude Sonnet 5.5, Titan Embeddings V2, Rerank.
- SSM parameters seeded from `config/<env>.json` (all thresholds in doc 05 §3).

## ObservabilityStack

- Log groups (KMS, 1-year retention), metric filters for `unresolved_citation`,
  `guardrail_block`, `abstention`.
- CloudWatch dashboard: chat latency stages, Bedrock tokens and cache ratio, cost per
  turn, pipeline throughput and lag, Neo4j metrics via CloudWatch agent (JMX).
- Alarms per doc 05 §5 routed to SNS → PagerDuty/Slack; composite alarm for "chat
  degraded".

## CI/CD

- GitHub Actions: `lint → unit → contract → cdk synth → cdk diff` on PR; `cdk deploy dev`
  on merge; manual approval for `staging`/`prod`; offline eval suites (doc 05 §2) run
  nightly and on changes under `prompts/`, `specs/`, `retrieval/`.
- Canary: prod ASG launches new image for 10 % of instances (weighted target groups) for
  48 h before full rollout; rollback = flip weights.
