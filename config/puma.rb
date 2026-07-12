require_relative "../lib/autotune"

plan = Autotune.summary
$stdout.puts "[autotune] #{plan.inspect}"

workers plan[:workers]
threads plan[:threads], plan[:threads]

# Bind to the port the platform injects (Heroku/Render/Fly all set PORT).
port ENV.fetch("PORT", 8080)
environment ENV.fetch("RAILS_ENV", "production")

preload_app!

# Re-establish the AR connection in each forked worker.
on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end

# Expose the chosen plan so /bench/info can report what actually ran. The two
# inputs (RSS estimate, target fraction) matter as much as the outputs: the
# worker count is only as honest as the RSS figure it was derived from.
ENV["AUTOTUNE_WORKERS"] = plan[:workers].to_s
ENV["AUTOTUNE_THREADS"] = plan[:threads].to_s
ENV["AUTOTUNE_TOTAL_MEM_MB"] = plan[:total_mem_mb].to_s
ENV["AUTOTUNE_CPU_COUNT"] = plan[:cpu_count].to_s
ENV["AUTOTUNE_WORKER_RSS_MB"] = plan[:worker_rss_mb].to_s
ENV["AUTOTUNE_TARGET_FRACTION"] = plan[:target_fraction].to_s
