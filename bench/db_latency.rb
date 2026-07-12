#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Standalone DB-latency probe. Talks directly to Postgres via the `pg` gem
# (no Rails/Puma in the path) to get CLEAN numbers, complementing the through-
# the-app /bench/db_latency endpoint. Run it from INSIDE an instance so the
# app->DB network path matches production topology.
#
#   gem install pg   # if not already present
#   DATABASE_URL=postgres://... ITERS=500 ruby bench/db_latency.rb
#
require "pg"
require "json"
require "uri"

url   = ENV.fetch("DATABASE_URL")
iters = (ENV["ITERS"] || 500).to_i

def pctl(sorted, p)
  return 0.0 if sorted.empty?
  k = [(p / 100.0 * (sorted.length - 1)).round, sorted.length - 1].min
  sorted[k]
end

def timed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000.0
end

conn = PG.connect(url)
conn.exec(<<~SQL)
  CREATE TABLE IF NOT EXISTS probe_rows (
    id bigserial primary key, token text, created_at timestamptz default now()
  )
SQL

results = {}
%w[select1 pk_read insert].each do |op|
  samples = []
  iters.times do
    ms =
      case op
      when "select1" then timed { conn.exec("SELECT 1") }
      when "pk_read"
        maxid = conn.exec("SELECT COALESCE(MAX(id),1) FROM probe_rows")[0]["coalesce"].to_i
        id = rand(1..maxid)
        timed { conn.exec_params("SELECT * FROM probe_rows WHERE id=$1", [id]) }
      when "insert"
        timed { conn.exec_params("INSERT INTO probe_rows(token) VALUES($1)", [rand.to_s]) }
      end
    samples << ms
  end
  s = samples.sort
  results[op] = {
    p50_ms: pctl(s, 50).round(3),
    p95_ms: pctl(s, 95).round(3),
    p99_ms: pctl(s, 99).round(3),
    min_ms: s.first.round(3),
    max_ms: s.last.round(3)
  }
end

out = {
  iters: iters,
  db_host: (URI.parse(url).host rescue nil),
  region: ENV["FLY_REGION"] || ENV["RENDER_REGION"] || ENV["HEROKU_REGION"] || ENV["REGION"],
  results: results
}
puts JSON.pretty_generate(out)
conn.close
