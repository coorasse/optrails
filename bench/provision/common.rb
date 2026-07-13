# frozen_string_literal: true

# Shared helpers for the provisioning scripts.
#
# These scripts exist so a benchmark run is reproducible: the tier, the region,
# the database plan and the env are the experiment's controls, and an experiment
# whose setup lives only in someone's shell history cannot be checked.

require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"

module Provision
  module_function

  ROOT = File.expand_path("../..", __dir__)

  # Puma sizes threads from THREADS_PER_WORKER and the autotuner sizes workers
  # from WORKER_RSS_MB. They MUST be identical on every platform in a run, or
  # the platforms are not being compared -- their configs are.
  SHARED_ENV = {
    "RAILS_ENV" => "production",
    "THREADS_PER_WORKER" => "5",
    "WORKER_RSS_MB" => "300",
    "SEED_ROWS" => "100000"
  }.freeze

  def run!(*cmd, quiet: false)
    out, err, status = Open3.capture3(*cmd)
    unless status.success?
      abort "FAILED: #{cmd.join(' ')}\n#{err.empty? ? out : err}"
    end
    warn out unless quiet || out.strip.empty?
    out
  end

  # Same command, but a failure is survivable (already exists, already gone).
  def try(*cmd)
    out, err, status = Open3.capture3(*cmd)
    [status.success?, status.success? ? out : err]
  end

  def secret_key_base = SecureRandom.hex(64)

  def strip_ansi(text) = text.gsub(/\e\[[0-9;]*m/, "")

  def step(message)
    warn "\n==> #{message}"
  end

  def wait_for_health(url, timeout: 900)
    step "waiting for #{url}/up"
    deadline = monotonic + timeout
    loop do
      code = http_code("#{url}/up")
      if code == "200"
        warn "    healthy"
        return true
      end
      abort "    never became healthy (last status #{code})" if monotonic > deadline

      warn "    #{code}..."
      sleep 10
    end
  end

  # The chosen autotune plan. Print it on every provision: a run whose worker and
  # thread counts were not recorded cannot be explained afterwards.
  def report_plan(url)
    info = JSON.parse(Net::HTTP.get(URI("#{url}/bench/info")))
    warn "\n    #{url}"
    warn "    autotune: #{info['workers']} workers x #{info['threads']} threads " \
         "| #{info['total_mem_mb']} MB | #{info['cpu_count']} vCPU reported"
    warn "    worker RSS: #{info['worker_rss_mb']} MB actual, " \
         "#{info['worker_rss_mb_setting']} MB assumed by the autotuner"
    warn "    db: #{info['db_host']}"
    info
  rescue StandardError => e
    warn "    could not read /bench/info: #{e.message}"
    nil
  end

  def http_code(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 10
    http.get(uri.path).code
  rescue StandardError
    "unreachable"
  end

  def confirm_destroy!(what)
    warn "\nAbout to DESTROY #{what}."
    warn "Type the name to confirm: "
    abort "aborted" unless $stdin.gets.to_s.strip == what
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
