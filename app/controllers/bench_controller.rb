require "benchmark"
require "digest"
require "securerandom"

# All endpoints return JSON and, where relevant, server-measured timings in
# milliseconds so you can separate app time from network/queue time on the
# load-generator side.
class BenchController < ApplicationController
  # Liveness only — used by platform health checks.
  def up
    render json: { ok: true }
  end

  # Reports what the autotuner actually chose + topology. Hit this once per
  # deploy and record it alongside results so every number is explainable.
  def info
    render json: {
      workers: ENV["AUTOTUNE_WORKERS"],
      threads: ENV["AUTOTUNE_THREADS"],
      total_mem_mb: ENV["AUTOTUNE_TOTAL_MEM_MB"],
      cpu_count: ENV["AUTOTUNE_CPU_COUNT"],
      # The estimate the plan was derived from, vs what this worker actually uses.
      worker_rss_mb_setting: ENV["AUTOTUNE_WORKER_RSS_MB"],
      target_fraction: ENV["AUTOTUNE_TARGET_FRACTION"],
      worker_rss_mb: current_rss_mb,
      ruby: RUBY_VERSION,
      rails: Rails.version,
      region: region,
      db_host: db_host,
      pid: Process.pid
    }
  end

  # CPU-bound: fixed, deterministic work. `work` scales the iteration count so
  # you can find the RPS knee. Pure compute — no allocation-heavy churn — so it
  # isolates the CPU share the platform really grants.
  def cpu
    n = clamp(params[:work].to_i, 1, 200, default: 20)
    acc = 0
    ms = Benchmark.realtime do
      (n * 1000).times do |i|
        acc = Digest::SHA256.hexdigest("#{acc}-#{i}").to_i(16) % 1_000_003
      end
    end * 1000
    render json: { work: n, result: acc, server_ms: ms.round(3) }
  end

  # IO/concurrency-bound: block for `ms` without using CPU. Shows how many
  # concurrent requests the worker/thread config can overlap.
  def io
    ms = clamp(params[:ms].to_i, 1, 2000, default: 50)
    actual = Benchmark.realtime { sleep(ms / 1000.0) } * 1000
    # Without server_ms the load side cannot tell app time from queue time, and
    # this is the one workload where that distinction is the whole point.
    render json: { slept_ms: ms, server_ms: actual.round(3) }
  end

  # DB read: indexed single-row lookup by primary key over the seeded table.
  def db_read
    max_id = BenchRecord.maximum(:id) || 1
    id = rand(1..max_id)
    rec = nil
    ms = Benchmark.realtime { rec = BenchRecord.find_by(id: id) }
    render json: { id: id, found: !rec.nil?, server_ms: (ms * 1000).round(3) }
  end

  # DB write: single INSERT + commit. Reflects the DB's durability/fsync path,
  # which ties back to disk performance.
  def db_write
    rec = nil
    ms = Benchmark.realtime do
      rec = BenchRecord.create!(token: SecureRandom.hex(12),
                                bucket: rand(1000),
                                payload: SecureRandom.hex(64))
    end
    render json: { id: rec.id, server_ms: (ms * 1000).round(3) }
  end

  # DB latency micro-suite, measured THROUGH the app stack (pool checkout
  # contention included). Reports each phase separately in ms.
  def db_latency
    checkout_ms = Benchmark.realtime do
      ActiveRecord::Base.connection_pool.with_connection { |c| c.active? }
    end * 1000

    select1_ms = Benchmark.realtime do
      ActiveRecord::Base.connection.execute("SELECT 1")
    end * 1000

    max_id = BenchRecord.maximum(:id) || 1
    pk_ms = Benchmark.realtime { BenchRecord.find_by(id: rand(1..max_id)) } * 1000

    insert_ms = Benchmark.realtime do
      BenchRecord.create!(token: SecureRandom.hex(12), bucket: rand(1000),
                          payload: SecureRandom.hex(64))
    end * 1000

    render json: {
      pool_checkout_ms: checkout_ms.round(3),
      select1_ms: select1_ms.round(3),
      pk_read_ms: pk_ms.round(3),
      insert_commit_ms: insert_ms.round(3),
      server_ms: (checkout_ms + select1_ms + pk_ms + insert_ms).round(3),
      region: region, db_host: db_host
    }
  end

  # Memory pressure: allocate ~`mb` of live strings and hold briefly. Use to
  # find where a tier OOMs / restarts. Bounded hard to avoid killing the box
  # accidentally during a normal load run.
  def mem
    mb = clamp(params[:mb].to_i, 1, 256, default: 32)
    blob = Array.new(mb) { "x" * (1024 * 1024) }
    size = blob.sum(&:bytesize)
    render json: { allocated_mb: (size / 1024.0 / 1024).round(1), rss_mb: current_rss_mb }
  end

  private

  def clamp(v, lo, hi, default:)
    return default if v.nil? || v.zero?
    [[v, lo].max, hi].min
  end

  def current_rss_mb
    kb = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
    (kb / 1024.0).round(1)
  rescue StandardError
    nil
  end

  def region
    ENV["FLY_REGION"] || ENV["RENDER_REGION"] || ENV["HEROKU_REGION"] || ENV["REGION"]
  end

  def db_host
    require "uri"
    URI.parse(ENV["DATABASE_URL"].to_s).host
  rescue StandardError
    nil
  end
end
