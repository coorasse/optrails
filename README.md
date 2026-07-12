# OptRails — a fair PaaS benchmark for Rails

RAM is roughly comparable across providers; advertised "vCPU / 1x / 2x" is not,
because it's all virtualized and subject to CPU steal. So this harness ignores
the marketing units and measures the only thing that matters:

> **Sustained requests/sec under a p95 latency SLO, per dollar/month** —
> for several representative Rails workloads, on each platform.

Deploy the *same* Docker image to Heroku, Render, and Fly.io, drive it with the
same load generator from a neutral location, and compare the curves.

## What it measures

| Dimension | How | Endpoint / tool |
|---|---|---|
| CPU-bound throughput | deterministic SHA loop, scalable | `/bench/cpu?work=N` |
| IO/concurrency | block N ms without CPU | `/bench/io?ms=N` |
| DB read | indexed PK lookup over 100k rows | `/bench/db_read` |
| DB write | INSERT + commit (hits fsync path) | `/bench/db_write` |
| DB latency (through app) | pool checkout + SELECT 1 + PK read + insert, p50/95/99 | `/bench/db_latency` |
| DB latency (isolated) | clean numbers via raw `pg`, no Rails in path | `bench/db_latency.rb` |
| Disk | seq read/write, random 4K IOPS, fsync latency | `bench/fio/diskbench.sh` |
| Memory ceiling | allocate & hold, watch for OOM/restart | `/bench/mem?mb=N` |
| Autotune report | workers/threads/mem/cpu actually chosen | `/bench/info` |

## Memory-scaled Puma (the core idea)

`lib/autotune.rb` sizes Puma at boot to fill **~80% of the container's memory**:

```
workers = floor(0.8 * container_RAM_MB / WORKER_RSS_MB), capped by CPU
threads = THREADS_PER_WORKER (default 5)
```

It reads the real cgroup memory/CPU limits the platform grants (not host RAM),
so bigger tiers genuinely get more workers — which is exactly how you'd run them.

**The finding this will expose:** more RAM only buys more throughput up to the
CPU ceiling for CPU-bound work. On a tier with lots of RAM but a thin CPU share
(classic Heroku higher tiers), extra workers just fight over the core — RPS
plateaus while p95 climbs. For IO/DB-bound work it keeps scaling because workers
block instead of burning CPU. `/bench/info` logs the chosen worker count and
per-worker RSS so every curve is explainable.

### Set `WORKER_RSS_MB` accurately per platform

The default (300 MB) is a placeholder. Measure it once on each platform after a
warm-up and set the env var, so the 80% target is honest:

```bash
# on a running instance
bundle exec rails runner 'puts (File.read("/proc/self/status")[/VmRSS:\s+(\d+)/,1].to_i/1024)'
```

## Fairness controls (where these benchmarks usually go wrong)

- **One image, deployed identically** — same Ruby 3.4 / Rails 8 / Puma config
  everywhere (`Dockerfile`). The only variable is the platform.
- **Co-located Postgres per platform** — DB in the *same region* as the app, so
  the number reflects that provider's own network + disk, not a shared managed
  DB someone is farther from. This is a deliberate choice; state it when you
  publish. (Alternative: one external DB for all three — then you're partly
  benchmarking distance to it.)
- **Load generator in a neutral location** — same origin for all three runs.
- **One pinned instance, autoscaling OFF** — `min=max=1`. Autoscale economics
  are a separate (also interesting) question.
- **Warm-up discarded** — ignore the first stage; Rails boot + pool warm-up skew
  early numbers.
- **Repeat across hours/days** — shared-CPU throughput swings with noisy
  neighbors. Report medians and spread, not a single heroic run.
- **DB pool ≥ Puma threads** — enforced in `database.yml`, so pool-checkout
  latency reflects the platform, not self-inflicted starvation.

## Deploy

Pick **one tier per platform per run** and record it. Provision a co-located DB.

**Fly.io** (`deploy/fly.toml`)
```bash
cp deploy/fly.toml fly.toml
fly launch --no-deploy            # or: fly apps create optrails-fly
fly postgres create --region fra  # match primary_region
fly postgres attach <pg-app>
fly volumes create optrails_data --region fra --size 10
fly deploy
```

**Render** (`deploy/render.yaml`) — push the repo, then New ▸ Blueprint and point
it at `render.yaml`. It provisions the web service, a persistent disk, and a
co-located Postgres.

**Heroku** (`deploy/heroku/`)
```bash
heroku create optrails-heroku
heroku stack:set container
cp deploy/heroku/heroku.yml heroku.yml
heroku addons:create heroku-postgresql:standard-0
git push heroku main
```
> Heroku dynos have **no persistent disk** — only an ephemeral filesystem wiped
> on restart/deploy. Run the fio test against `/tmp` there and label it
> *ephemeral*; "persistent disk performance" is N/A by design.

## Run the benchmark

Per platform, per scenario (from a neutral machine with [k6](https://k6.io) installed):

```bash
BASE_URL=https://optrails-fly.fly.dev SCENARIO=db_read \
  k6 run --out json=raw.json bench/k6/load.js
# produces summary.json
mv summary.json results/fly_shared-1x-1gb_db_read.json
```

Scenarios: `cpu`, `io`, `db_read`, `db_write`, `db_latency`, `mixed`.
Knobs: `START_RPS`, `MAX_RPS`, `STAGE_SEC`, `SLO_MS`, `WORK`, `IO_MS`.

Disk + isolated DB latency (run *inside* an instance):
```bash
TARGET_DIR=/data ./bench/fio/diskbench.sh      # persistent volume (Fly/Render)
TARGET_DIR=/tmp  ./bench/fio/diskbench.sh      # ephemeral (all, incl. Heroku)
DATABASE_URL=$DATABASE_URL ITERS=500 ruby bench/db_latency.rb
```

## Crunch the results

```bash
python3 bench/results/crunch.py --slo-ms 200 \
  --result platform=fly    tier=shared-1x-1gb scenario=db_read summary=results/fly_shared-1x-1gb_db_read.json \
  --result platform=render tier=Standard      scenario=db_read summary=results/render_standard_db_read.json \
  --result platform=heroku tier=Standard-2X   scenario=db_read summary=results/heroku_std2x_db_read.json
```

Prints a table and writes `rps_per_dollar.png`. A run only counts its RPS toward
the score if its p95 actually held under the SLO — so you're comparing *usable*
throughput per dollar, not raw numbers at unacceptable latency.

Prices live in `bench/prices.json` (list prices, July 2026 — verify before
publishing; Fly is pay-as-you-go normalized to ~730h always-on).

## Caveats worth stating when you publish

- Shared-CPU results are inherently noisy; one number is a lie, a distribution is
  the truth.
- Co-located self-managed Postgres favors whoever has the fastest local disk
  (Fly's local NVMe tends to win `db_write`/fsync); a managed-DB setup would
  shift that. Both are valid — just be explicit about which you ran.
- `WORKER_RSS_MB` and the CPU cap heuristics change absolute worker counts; keep
  them identical across platforms and record them.
