# Project: ML-Based Predictive Cloud Resource Management

Read PLAN.md first. It is the source of truth for architecture and phases.
Build ONE stage at a time. Never start the next stage unless I say so.

## Environment
- Windows 11, PowerShell, Python 3.11 venv at .venv
- Cloud: AWS ap-south-1, one EC2 Amazon Linux VM running Docker
- I run AWS Console steps and SSH/scp myself. Give me exact commands.

## Hard rules
1. Never fabricate data. Missing fields stay NaN. Never fill with zeros or invented values.
2. Never put AWS keys or secrets in code. Use env vars or IAM roles.
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
10. Do not run anything that costs money or touches AWS. Only write code/scripts.
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