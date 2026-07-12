require "rails_helper"
require "erb"
require "yaml"

RSpec.describe OptRails::Application do
  describe "production boot" do
    # Production sets eager_load = true, so a class that fails to load takes the
    # whole dyno down at boot rather than failing a single request. Test builds
    # run with eager_load off, so without this the gap only shows up in prod.
    it "loads every class in the app" do
      expect { Rails.application.eager_load! }.not_to raise_error
    end
  end

  describe "fairness invariants" do
    # If the pool is smaller than the thread count, requests queue on
    # pool checkout and we measure our own starvation instead of the platform.
    def pool_size(env)
      original = ENV.to_hash
      env.each { |k, v| ENV[k.to_s] = v.to_s }
      yaml = ERB.new(Rails.root.join("config/database.yml").read).result
      YAML.safe_load(yaml, aliases: true).fetch("production").fetch("pool")
    ensure
      ENV.replace(original)
    end

    def threads_for(env)
      original = ENV.to_hash
      env.each { |k, v| ENV[k.to_s] = v.to_s }
      Autotune.threads
    ensure
      ENV.replace(original)
    end

    it "keeps the DB pool at least as large as the Puma thread count by default" do
      expect(pool_size({})).to be >= threads_for({})
    end

    it "keeps the pool wide enough when threads are raised via THREADS_PER_WORKER" do
      env = { THREADS_PER_WORKER: 16 }

      expect(pool_size(env)).to be >= threads_for(env)
    end

    it "keeps the pool wide enough when threads are raised via RAILS_MAX_THREADS" do
      env = { RAILS_MAX_THREADS: 16 }

      expect(pool_size(env)).to be >= threads_for(env)
    end

    it "matches the pool of the running connection to the configured threads" do
      expect(ActiveRecord::Base.connection_pool.size).to be >= Autotune.threads
    end
  end
end
