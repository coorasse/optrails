# frozen_string_literal: true
#
# Autotune Puma concurrency to a target fraction of the *container's* memory.
#
# Idea: more RAM should buy more Puma workers (real MRI parallelism) until we
# hit the CPU ceiling. We size workers to fill ~80% of available memory using a
# measured/estimated per-worker RSS, then cap by vCPU-derived limits.
#
# Everything is overridable via env so a run is reproducible and auditable.
module Autotune
  module_function

  # Total memory available to THIS container, in MB.
  # Reads cgroup limits first (what the platform actually grants), then falls
  # back to host meminfo. Guards against the cgroup "unlimited" sentinel.
  def total_mem_mb
    if (env = ENV["TOTAL_MEM_MB"])
      return env.to_i
    end

    candidates = []
    # cgroup v2
    if File.exist?("/sys/fs/cgroup/memory.max")
      v = File.read("/sys/fs/cgroup/memory.max").strip
      candidates << v.to_i if v =~ /\A\d+\z/
    end
    # cgroup v1
    if File.exist?("/sys/fs/cgroup/memory/memory.limit_in_bytes")
      v = File.read("/sys/fs/cgroup/memory/memory.limit_in_bytes").strip.to_i
      # Ignore the ~unlimited sentinel (very large number)
      candidates << v if v.positive? && v < (1 << 62)
    end
    bytes = candidates.min
    return (bytes / (1024 * 1024)) if bytes && bytes.positive?

    # Fallback: host RAM from /proc/meminfo (kB)
    if File.exist?("/proc/meminfo")
      kb = File.read("/proc/meminfo")[/MemTotal:\s+(\d+)/, 1].to_i
      return kb / 1024 if kb.positive?
    end
    512 # last-resort default
  end

  def cpu_count
    return ENV["CPU_COUNT"].to_i if ENV["CPU_COUNT"]
    # cgroup v2 cpu.max = "quota period"; quota/period ~ effective cores
    if File.exist?("/sys/fs/cgroup/cpu.max")
      quota, period = File.read("/sys/fs/cgroup/cpu.max").split
      if quota != "max" && period.to_i.positive?
        eff = (quota.to_f / period.to_f).ceil
        return [eff, 1].max
      end
    end
    require "etc"
    Etc.nprocessors
  rescue StandardError
    1
  end

  # Per-worker resident memory estimate in MB. Override with a measured value
  # (see `rails runner` snippet in the README) for accuracy on each platform.
  def worker_rss_mb
    (ENV["WORKER_RSS_MB"] || 300).to_i
  end

  def target_fraction
    (ENV["MEM_TARGET_FRACTION"] || 0.8).to_f
  end

  # Workers sized to fill target fraction of RAM, then capped so we don't wildly
  # oversubscribe CPU. The cap is generous (workers can block on IO/DB), but
  # keeps a 1-vCPU box from spawning 12 CPU-starved workers by default.
  def workers
    return ENV["WEB_CONCURRENCY"].to_i if ENV["WEB_CONCURRENCY"]
    budget = (total_mem_mb * target_fraction).floor
    by_mem = [budget / worker_rss_mb, 1].max
    cpu_cap = (cpu_count * (ENV["WORKERS_PER_CPU"] || 4).to_i)
    [by_mem, cpu_cap].min
  end

  def threads
    return ENV["RAILS_MAX_THREADS"].to_i if ENV["RAILS_MAX_THREADS"]
    (ENV["THREADS_PER_WORKER"] || 5).to_i
  end

  def summary
    {
      total_mem_mb: total_mem_mb,
      cpu_count: cpu_count,
      worker_rss_mb: worker_rss_mb,
      target_fraction: target_fraction,
      workers: workers,
      threads: threads
    }
  end
end
