# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OptRails is a **PaaS benchmark harness**, not a product. It is a deliberately
minimal Rails 8 API-only app (`config.api_only = true`, no views/assets/JS) whose
sole purpose is to be deployed as *one identical Docker image* to Heroku, Render,
and Fly.io and measured. The single question it answers: **sustained requests/sec
under a p95 latency SLO, per dollar/month**, across representative Rails workloads.

Read `README.md` first — it documents the methodology, fairness controls, and the
core finding the harness is designed to expose. Do not "improve" the app with
features; every part exists to make a benchmark number honest and reproducible.

## Architecture

Three layers, kept separate on purpose:

1. **The app under test** (`app/`, `config/`, `db/`) — a tiny Rails app exposing
   benchmark endpoints. `BenchController` (`app/controllers/bench_controller.rb`)
   is the whole surface: one action per workload dimension, each returning JSON
   with server-measured `server_ms` so the load side can separate app time from
   network/queue time. `BenchRecord` is the only model; `db/seeds.rb` fills it to
   `SEED_ROWS` (default 100k) so `db_read` hits an index over a non-trivial table.

2. **The autotuner** (`lib/autotune.rb`, wired in `config/puma.rb`) — the core
   idea. At boot it reads the container's *real cgroup memory/CPU limits* (v2
   then v1, then `/proc/meminfo` fallback) and sizes Puma workers to fill ~80% of
   RAM: `workers = floor(0.8 * RAM_MB / WORKER_RSS_MB)`, capped by `WORKERS_PER_CPU
   * cpu_count`. This makes bigger tiers genuinely get more workers. The chosen
   plan is stashed in `AUTOTUNE_*` env vars and reported by `GET /bench/info` so
   every RPS curve is explainable. Everything is env-overridable for reproducibility.

3. **The measurement tooling** (`bench/`) — runs from *outside* (neutral load
   generator) and *inside* (disk/DB probes) the instances:
   - `bench/k6/load.js` — k6 ramping-arrival-rate driver. Run from a neutral
     location against each platform URL; ramps RPS until the p95 SLO breaks.
   - `bench/db_latency.rb` — standalone `pg`-only DB latency probe (no Rails in
     the path) for clean numbers; run inside an instance.
   - `bench/fio/diskbench.sh` — fio disk benchmark; run inside an instance.
   - `bench/results/crunch.py` — ingests k6 summaries + `bench/prices.json` and
     prints the RPS-per-dollar table / `rps_per_dollar.png`. **Only counts a run's
     RPS if its p95 actually held under the SLO** (see `crunch.py` `rps_eff`).

Deploy configs in `deploy/` (fly.toml, render.yaml, heroku/) are three encodings
of the *same* deployment: one pinned instance (autoscale off, `min=max=1`),
co-located Postgres in the same region, persistent volume at `/data` (except
Heroku, which is ephemeral-only by design).

## Invariants — do not break these

These enforce benchmark fairness. Changing them silently invalidates comparisons.

- **One image, deployed identically.** The only variable across runs is the
  platform. Don't add platform-specific code paths in the app.
- **DB pool ≥ Puma threads.** Enforced in `config/database.yml` and
  `config/application.rb` so pool-checkout latency reflects the platform, not
  self-inflicted starvation. Keep both in sync if you touch thread counts.
- **`WORKER_RSS_MB` (default 300) is a placeholder** meant to be measured per
  platform and set via env (README has the `rails runner` snippet). Keep it and
  the CPU-cap heuristics identical across platforms within a run, and record them.
- **Autoscale off, one instance.** `deploy/*` pin `numInstances: 1` /
  `min_machines_running = 1` / `quantity: 1`. Don't enable autoscaling.
- **No SSL redirect** (`config.force_ssl = false`) — TLS terminates at the edge;
  we benchmark the app, not the redirect.
- **Endpoints are bounded** (`clamp` in `BenchController`) so a load run can't
  accidentally OOM/peg the box outside the intended parameter.

## Commands

There is no test suite, and no `bin/setup` / `bin/check` / `bin/fastcheck`. This
is a benchmark harness; you exercise it by running it, not by unit tests.

Local run (needs Postgres at `postgres://localhost/optrails_dev`, override with
`DATABASE_URL`):

```bash
bundle install
bundle exec rails db:prepare
SEED_ROWS=1000 bundle exec rails runner 'load Rails.root.join("db/seeds.rb")'
bundle exec puma -C config/puma.rb        # boots on PORT or 8080
curl localhost:8080/bench/info            # see the autotune plan that was chosen
```

Benchmark workflow (see README for full flow):

```bash
# 1. drive load from a neutral machine (k6 installed), per platform + scenario
BASE_URL=https://optrails-fly.fly.dev SCENARIO=db_read \
  k6 run --out json=raw.json bench/k6/load.js
mv summary.json bench/results/fly_shared-1x-1gb_db_read.json

# 2. run disk + isolated-DB probes INSIDE an instance
TARGET_DIR=/data ./bench/fio/diskbench.sh
DATABASE_URL=$DATABASE_URL ITERS=500 ruby bench/db_latency.rb

# 3. crunch summaries into the RPS-per-dollar table + chart
python3 bench/results/crunch.py --slo-ms 200 \
  --result platform=fly tier=shared-1x-1gb scenario=db_read \
    summary=bench/results/fly_shared-1x-1gb_db_read.json
```

k6 scenarios: `cpu`, `io`, `db_read`, `db_write`, `db_latency`, `mixed`.
k6 knobs (env): `START_RPS`, `MAX_RPS`, `STAGE_SEC`, `SLO_MS`, `WORK`, `IO_MS`.

## Deploy

Pick **one tier per platform per run and record it**, and provision a co-located
DB. Ruby is pinned by `.ruby-version` / `Dockerfile` (`ruby:3.4-slim`); `Gemfile`
allows `>= 3.3`. The container CMD migrates + idempotently seeds, then boots Puma.
Per-platform env and provisioning steps are in `deploy/` and the README.
