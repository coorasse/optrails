require "rails_helper"

RSpec.describe Autotune do
  # Autotune reads ENV on every call, so setting it is enough — no stubbing.
  def with_env(vars)
    original = ENV.to_hash
    vars.each { |k, v| ENV[k.to_s] = v.to_s }
    yield
  ensure
    ENV.replace(original)
  end

  describe ".total_mem_mb" do
    it "prefers an explicit override so a run is reproducible" do
      with_env(TOTAL_MEM_MB: 2048) do
        expect(described_class.total_mem_mb).to eq(2048)
      end
    end
  end

  describe ".workers" do
    it "fills the target fraction of memory" do
      # 80% of 2048 = 1638 MB budget / 256 MB per worker = 6
      with_env(TOTAL_MEM_MB: 2048, WORKER_RSS_MB: 256, CPU_COUNT: 8) do
        expect(described_class.workers).to eq(6)
      end
    end

    it "gives a bigger tier more workers" do
      small = with_env(TOTAL_MEM_MB: 1024, WORKER_RSS_MB: 256, CPU_COUNT: 8) { described_class.workers }
      large = with_env(TOTAL_MEM_MB: 4096, WORKER_RSS_MB: 256, CPU_COUNT: 8) { described_class.workers }

      expect(large).to be > small
    end

    it "caps at WORKERS_PER_CPU * cpu_count so a 1-vCPU box is not oversubscribed" do
      # Memory alone would allow 65 workers; the CPU cap is 1 * 4.
      with_env(TOTAL_MEM_MB: 8192, WORKER_RSS_MB: 100, CPU_COUNT: 1, WORKERS_PER_CPU: 4) do
        expect(described_class.workers).to eq(4)
      end
    end

    it "always keeps at least one worker when memory is below one worker's RSS" do
      with_env(TOTAL_MEM_MB: 100, WORKER_RSS_MB: 300, CPU_COUNT: 1) do
        expect(described_class.workers).to eq(1)
      end
    end

    it "sizes a 512 MB tier to a single worker" do
      # The deployed Heroku Basic case: 80% of 512 = 409 MB, under 2x the RSS.
      with_env(TOTAL_MEM_MB: 512, WORKER_RSS_MB: 300, CPU_COUNT: 8) do
        expect(described_class.workers).to eq(1)
      end
    end

    it "honours an explicit WEB_CONCURRENCY override" do
      with_env(WEB_CONCURRENCY: 3, TOTAL_MEM_MB: 8192, WORKER_RSS_MB: 100) do
        expect(described_class.workers).to eq(3)
      end
    end

    it "respects a custom memory target fraction" do
      with_env(TOTAL_MEM_MB: 1000, WORKER_RSS_MB: 100, CPU_COUNT: 8, MEM_TARGET_FRACTION: 0.5) do
        expect(described_class.workers).to eq(5)
      end
    end
  end

  describe ".threads" do
    it "defaults to five per worker" do
      with_env({}) { expect(described_class.threads).to eq(5) }
    end

    it "honours THREADS_PER_WORKER" do
      with_env(THREADS_PER_WORKER: 8) { expect(described_class.threads).to eq(8) }
    end

    it "lets RAILS_MAX_THREADS win, since that is what the DB pool is sized from" do
      with_env(RAILS_MAX_THREADS: 12, THREADS_PER_WORKER: 5) do
        expect(described_class.threads).to eq(12)
      end
    end
  end

  describe ".summary" do
    it "reports the whole plan so every RPS curve is explainable" do
      with_env(TOTAL_MEM_MB: 2048, WORKER_RSS_MB: 256, CPU_COUNT: 4) do
        expect(described_class.summary).to eq(
          total_mem_mb: 2048,
          cpu_count: 4,
          worker_rss_mb: 256,
          target_fraction: 0.8,
          workers: 6,
          threads: 5
        )
      end
    end
  end
end
