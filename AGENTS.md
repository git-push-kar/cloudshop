# Project: ML-Based Predictive Cloud Resource Management

Read PLAN.md first. It is the source of truth for architecture and phases.
Build ONE stage at a time. Never start the next stage unless I say so.

## Environment
- Windows 11, PowerShell, Python 3.11 venv at .venv
- Cloud: Microsoft Azure, region Central India, one Linux VM running Docker,
  inside a single resource group named rg-predictive-cloud
- I run Azure Portal / az CLI steps and SSH/scp myself. Give me exact commands.

## Hard rules
1. Never fabricate data. Missing fields stay NaN. Never fill with zeros or invented values.
2. Never put Azure credentials or secrets in code. Use env vars or managed
   identities.
3. Chronological train/test splits only. No shuffling. No future leakage in features.
4. The ML model never executes cloud actions directly. Only controller/policy.py
   decides, with guardrails (min/max replicas, cooldowns, budget, stale-metric checks).
5. Controller must have modes: shadow (log only) and active. Default = shadow.
6. Split dependencies: requirements-api.txt (fastapi, uvicorn only, used in Docker)
   and requirements-dev.txt (everything else).
7. Every script must be runnable from the project root and have CLI args or
   top-of-file constants, plus a short docstring saying what it does.
8. After each stage, give me: (a) files created/changed, (b) exact commands to
   run and verify, (c) what "success" looks like, (d) what I must do manually.
9. If something in PLAN.md is ambiguous or wrong, say so and propose a fix
   before coding.
10. Azure mapping: EC2 = Azure VM, Security Group = NSG, CloudWatch = Azure Monitor,
    IAM role = managed identity + role assignment, ECR = ACR, Auto Scaling Group =
    VM Scale Set (Level 2 only). The plan's AWS references are replaced by these.
11. Do not run anything that costs money or touches Azure. Only write code/scripts.
    I execute those.

## Structure
Follow the tree in PLAN.md, plus: deploy/ (docker-compose.yml, nginx.conf),
docs/ (README sections, dataset notes), and tests/.

## Known fixes to PLAN.md
- Add stateless POST /orders to app/main.py (validate product_id exists, return 404 otherwise).
- Complete the DemandShape LoadTestShape in loadtest/locustfile.py with selectable
  patterns A-E (steady, ramp, burst, spike-then-drop, repeated peaks) chosen by
  env var PATTERN, with documented durations.
- Target column: target_request_rate_5m = request_rate shifted -5 (1-min data).
- Level 1 scaling = docker compose + nginx upstream, N app replicas with CPU/memory limits.