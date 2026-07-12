#!/usr/bin/env ruby
# frozen_string_literal: true

# Collect one benchmark run from a deployed OptRails instance and record it.
#
# Point this at any platform/tier. It captures the autotune plan from
# /bench/info, drives k6 through each scenario, scores every result against the
# SLO, prices it from bench/prices.json, writes a machine-readable record to
# docs/results/, and re-renders docs/BENCHMARKS.md.
#
#   ruby bench/collect.rb \
#     --platform heroku --tier Basic \
#     --url https://optrails-heroku-189a76ca2865.herokuapp.com \
#     --db essential-0:5 \
#     --driven-from "hetzner fsn1"
#
# Drive load from a NEUTRAL host — not your laptop, not inside any provider's
# network — and use the SAME invocation for every platform, or the comparison
# is not a comparison. Use --no-load to record topology only (no k6 needed).

require "json"
require "net/http"
require "uri"
require "time"
require "open3"
require "optparse"
require "fileutils"
require "tmpdir"
require_relative "aggregate"

module Collect
  module_function

  ROOT        = File.expand_path("..", __dir__)
  RESULTS_DIR = File.join(ROOT, "docs", "results")
  PRICES      = File.join(ROOT, "bench", "prices.json")
  LOAD_SCRIPT = File.join(ROOT, "bench", "k6", "load.js")

  ALL_SCENARIOS = %w[cpu io db_read db_write db_latency mixed].freeze

  def options
    opts = {
      scenarios: %w[cpu io db_read db_write mixed],
      slo_ms: 200,
      start_rps: 10,
      max_rps: 500,
      stage_sec: 30,
      load: true,
      notes: []
    }

    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby bench/collect.rb --platform NAME --tier NAME --url URL [options]"
      o.on("--platform NAME", "heroku | render | fly")                    { |v| opts[:platform] = v }
      o.on("--tier NAME", "must match a tier in bench/prices.json")       { |v| opts[:tier] = v }
      o.on("--url URL", "base url of the deployed instance")              { |v| opts[:url] = v.chomp("/") }
      o.on("--scenarios LIST", "default: #{opts[:scenarios].join(',')}")  { |v| opts[:scenarios] = v.split(",") }
      o.on("--slo-ms MS", Integer, "p95 ceiling (default 200)")           { |v| opts[:slo_ms] = v }
      o.on("--start-rps N", Integer)                                      { |v| opts[:start_rps] = v }
      o.on("--max-rps N", Integer)                                        { |v| opts[:max_rps] = v }
      o.on("--stage-sec N", Integer)                                      { |v| opts[:stage_sec] = v }
      o.on("--db PLAN:USD", "e.g. essential-0:5")                         { |v| opts[:db] = v }
      o.on("--usd-month N", Float, "override the price in prices.json")   { |v| opts[:usd_month] = v }
      o.on("--driven-from PLACE", "where the load generator ran")         { |v| opts[:driven_from] = v }
      o.on("--note TEXT", "repeatable caveat, recorded verbatim")         { |v| opts[:notes] << v }
      o.on("--no-load", "record topology only; skip k6")                  { opts[:load] = false }
    end
    parser.parse!

    missing = %i[platform tier url].reject { |k| opts[k] }
    abort "#{parser}\n\nmissing: #{missing.join(', ')}" if missing.any?

    unknown = opts[:scenarios] - ALL_SCENARIOS
    abort "unknown scenario(s): #{unknown.join(', ')} (known: #{ALL_SCENARIOS.join(', ')})" if unknown.any?

    opts
  end

  def fetch_info(url)
    res = Net::HTTP.get_response(URI("#{url}/bench/info"))
    abort "GET #{url}/bench/info returned #{res.code} — is the app up?" unless res.code == "200"
    JSON.parse(res.body)
  rescue StandardError => e
    abort "could not reach #{url}: #{e.message}"
  end

  # The k6 summary reflects the whole ramp, so a run counts only if its p95 held
  # for the entire ramp. That is deliberately strict: see docs/BENCHMARKS.md.
  def run_k6(opts, scenario)
    abort "k6 not found on PATH — install it (brew install k6) or pass --no-load" unless k6?

    Dir.mktmpdir do |dir|
      summary = File.join(dir, "summary.json")
      env = {
        "BASE_URL" => opts[:url], "SCENARIO" => scenario,
        "START_RPS" => opts[:start_rps].to_s, "MAX_RPS" => opts[:max_rps].to_s,
        "STAGE_SEC" => opts[:stage_sec].to_s, "SLO_MS" => opts[:slo_ms].to_s
      }
      warn "  k6: #{scenario} (#{opts[:start_rps]}->#{opts[:max_rps]} RPS)..."
      # load.js writes summary.json into the working directory.
      _out, err, status = Open3.capture3(env, "k6", "run", LOAD_SCRIPT, chdir: dir)
      abort "k6 failed for #{scenario}:\n#{err}" unless status.success?

      parse_summary(JSON.parse(File.read(summary)))
    end
  end

  def parse_summary(data)
    metrics = data["metrics"] || {}
    duration = metrics.dig("http_req_duration", "values") || {}
    {
      "p95_ms" => duration["p(95)"] || duration["p95"],
      "rps" => metrics.dig("http_reqs", "values", "rate"),
      "ok_rate" => metrics.dig("endpoint_ok", "values", "rate")
    }
  end

  # Mirrors crunch.py's rps_eff: RPS that broke the SLO is worth nothing.
  #
  # Priced two ways on purpose. Compute-only is what crunch.py and the README
  # already report and is what compares like for like across platforms; total
  # is what the bill actually says. They can rank platforms differently when one
  # bundles a cheap-but-weak database, so both are shown and neither is hidden.
  def score(result, slo_ms, usd_compute, usd_total)
    met = !result["p95_ms"].nil? && result["p95_ms"] <= slo_ms
    rps_eff = met ? result["rps"].to_f : 0.0
    result.merge(
      "met_slo" => met,
      "rps_eff" => rps_eff,
      "rps_per_usd" => per_dollar(rps_eff, usd_compute),
      "rps_per_usd_total" => per_dollar(rps_eff, usd_total)
    )
  end

  def per_dollar(rps_eff, usd)
    usd.to_f.positive? ? (rps_eff / usd.to_f) : nil
  end

  def price_for(platform, tier, override)
    tiers = JSON.parse(File.read(PRICES))["tiers"]
    match = tiers.find do |t|
      t["platform"].casecmp?(platform) && t["tier"].casecmp?(tier)
    end

    if match.nil? && override.nil?
      warn "WARNING: no price for #{platform}/#{tier} in bench/prices.json and no " \
           "--usd-month given. RPS/$ will be blank. Known tiers for #{platform}: " \
           "#{tiers.select { |t| t['platform'].casecmp?(platform) }.map { |t| t['tier'] }.join(', ')}"
    end

    (match || {}).merge("usd_month" => override || match&.fetch("usd_month", nil)).compact
  end

  def db_for(spec)
    return nil unless spec

    plan, usd = spec.split(":")
    { "plan" => plan, "usd_month" => usd&.to_f }.compact
  end

  def git_sha
    sha, status = Open3.capture2("git", "rev-parse", "--short", "HEAD", chdir: ROOT)
    status.success? ? sha.strip : nil
  end

  def k6?
    _o, _e, status = Open3.capture3("which", "k6")
    status.success?
  end

  def call
    opts = options
    info = fetch_info(opts[:url])
    price = price_for(opts[:platform], opts[:tier], opts[:usd_month])
    db = db_for(opts[:db])

    usd_compute = price["usd_month"]
    usd_total = usd_compute ? usd_compute.to_f + db&.fetch("usd_month", 0).to_f : nil

    warn "collecting #{opts[:platform]}/#{opts[:tier]} from #{opts[:url]}"
    warn "  autotune: #{info['workers']} workers x #{info['threads']} threads, " \
         "#{info['total_mem_mb']} MB, #{info['worker_rss_mb']} MB RSS/worker"

    scenarios = {}
    if opts[:load]
      opts[:scenarios].each do |scenario|
        scenarios[scenario] = score(run_k6(opts, scenario), opts[:slo_ms], usd_compute, usd_total)
      end
    else
      warn "  --no-load: topology only, no k6"
    end

    record = {
      "platform" => opts[:platform],
      "tier" => opts[:tier],
      "url" => opts[:url],
      "collected_at" => Time.now.utc.iso8601,
      "git_sha" => git_sha,
      "slo_ms" => opts[:slo_ms],
      "price" => price.merge("usd_month_total" => usd_total).compact,
      "db" => db,
      "info" => info,
      # The worker count is only as honest as the RSS estimate it was derived
      # from, so record what the instance was actually configured with.
      "env" => { "worker_rss_mb" => info["worker_rss_mb_setting"],
                 "target_fraction" => info["target_fraction"] }.compact,
      "load" => opts[:load] ? opts.slice(:start_rps, :max_rps, :stage_sec).transform_keys(&:to_s)
                                  .merge("driven_from" => opts[:driven_from]) : nil,
      "scenarios" => scenarios,
      "notes" => opts[:notes]
    }.compact

    FileUtils.mkdir_p(RESULTS_DIR)
    slug = "#{opts[:platform]}__#{opts[:tier]}__#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
             .downcase.gsub(/[^a-z0-9_\-]/, "-")
    path = File.join(RESULTS_DIR, "#{slug}.json")
    File.write(path, JSON.pretty_generate(record))

    doc = Aggregate.write
    warn "\nrecorded  -> #{path.sub("#{ROOT}/", '')}"
    warn "aggregated -> #{doc.sub("#{ROOT}/", '')}"
  end
end

require "tmpdir"
Collect.call if $PROGRAM_NAME == __FILE__
