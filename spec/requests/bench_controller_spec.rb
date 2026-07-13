require "rails_helper"

RSpec.describe BenchController do
  def json = JSON.parse(response.body)

  describe "#up" do
    it "reports liveness" do
      get "/up"

      expect(response).to have_http_status(:ok)
      expect(json).to eq("ok" => true)
    end
  end

  describe "#info" do
    it "reports the autotune plan and topology" do
      get "/bench/info"

      expect(response).to have_http_status(:ok)
      expect(json).to include("workers", "threads", "total_mem_mb", "cpu_count",
                              "worker_rss_mb", "worker_rss_mb_setting", "target_fraction",
                              "region", "db_host")
      expect(json["ruby"]).to eq(RUBY_VERSION)
      expect(json["rails"]).to eq(Rails.version)
      expect(json["pid"]).to eq(Process.pid)
    end
  end

  describe "#cpu" do
    it "runs the default amount of work" do
      get "/bench/cpu"

      expect(response).to have_http_status(:ok)
      expect(json["work"]).to eq(20)
      expect(json["server_ms"]).to be > 0
    end

    it "scales with the work parameter" do
      get "/bench/cpu", params: { work: 5 }

      expect(json["work"]).to eq(5)
    end

    it "is deterministic for a given work size" do
      get "/bench/cpu", params: { work: 1 }
      first = json["result"]
      get "/bench/cpu", params: { work: 1 }

      expect(json["result"]).to eq(first)
    end

    it "clamps work to the upper bound so a load run cannot peg the box" do
      get "/bench/cpu", params: { work: 10_000 }

      expect(json["work"]).to eq(200)
    end

    it "clamps work to the lower bound" do
      get "/bench/cpu", params: { work: -5 }

      expect(json["work"]).to eq(1)
    end
  end

  describe "#io" do
    it "sleeps for the default duration" do
      get "/bench/io"

      expect(response).to have_http_status(:ok)
      expect(json["slept_ms"]).to eq(50)
    end

    it "sleeps for the requested duration" do
      get "/bench/io", params: { ms: 10 }

      expect(json["slept_ms"]).to eq(10)
    end

    # Without this the load side cannot separate app time from queue time, and
    # the IO dimension reports an app time of zero at every rate.
    it "reports server time so the load side can subtract queueing" do
      get "/bench/io", params: { ms: 10 }

      expect(json["server_ms"]).to be >= 10
    end

    it "clamps the sleep to the upper bound" do
      get "/bench/io", params: { ms: 10_000 }

      expect(json["slept_ms"]).to eq(2000)
    end
  end

  describe "#db_read" do
    before { create_bench_records(3) }

    it "reads a row by primary key and reports server time" do
      get "/bench/db_read"

      expect(response).to have_http_status(:ok)
      expect(json["id"]).to be_a(Integer)
      expect(json["found"]).to be_in([true, false])
      expect(json["server_ms"]).to be >= 0
    end
  end

  describe "#db_write" do
    it "inserts a row and returns its id" do
      expect { get "/bench/db_write" }.to change(BenchRecord, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(json["id"]).to eq(BenchRecord.last.id)
      expect(json["server_ms"]).to be >= 0
    end

    it "is reachable over POST as well" do
      expect { post "/bench/db_write" }.to change(BenchRecord, :count).by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "#db_latency" do
    before { create_bench_records(3) }

    it "reports each phase of the round trip separately" do
      expect { get "/bench/db_latency" }.to change(BenchRecord, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(json["pool_checkout_ms"]).to be >= 0
      expect(json["select1_ms"]).to be >= 0
      expect(json["pk_read_ms"]).to be >= 0
      expect(json["insert_commit_ms"]).to be >= 0
      expect(json["server_ms"]).to be >= 0
    end
  end

  describe "#mem" do
    it "allocates the requested amount" do
      get "/bench/mem", params: { mb: 1 }

      expect(response).to have_http_status(:ok)
      expect(json["allocated_mb"]).to eq(1.0)
    end

    it "clamps the allocation so a load run cannot OOM the box" do
      get "/bench/mem", params: { mb: 100_000 }

      expect(json["allocated_mb"]).to eq(256.0)
    end
  end

  def create_bench_records(count)
    count.times do
      BenchRecord.create!(token: SecureRandom.hex(12), bucket: rand(1000),
                          payload: SecureRandom.hex(64))
    end
  end
end
