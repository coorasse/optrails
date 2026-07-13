#!/usr/bin/env ruby
# frozen_string_literal: true

# Provision a complete Deploio benchmark target, from nothing to a URL that
# serves /bench/info.
#
#   ruby bench/provision/deploio.rb --app optrails-dp-2
#   ruby bench/provision/deploio.rb --app optrails-dp-2 --destroy
#
# Deploio builds from the GIT REMOTE, not your working copy, so the commit you
# want MUST be pushed first. The script refuses to run otherwise: a target
# silently running a different commit than the Heroku one destroys the whole
# comparison, and that failure is invisible in the results.

require "optparse"
require_relative "common"

module DeploioTarget
  module_function

  DEFAULTS = {
    project: "renuotest-optrails",
    size: "mini",
    location: "nine-cz42",     # co-locate app and DB, or db_latency measures the WAN
    git_url: "https://github.com/coorasse/optrails.git",
    revision: "master"
  }.freeze

  def options
    opts = DEFAULTS.dup
    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby bench/provision/deploio.rb --app NAME [options]"
      o.on("--app NAME", "app name (required)")                       { |v| opts[:app] = v }
      o.on("--project P", "default: #{DEFAULTS[:project]}")           { |v| opts[:project] = v }
      o.on("--size S", "micro|mini|standard-1|... default: #{DEFAULTS[:size]}") { |v| opts[:size] = v }
      o.on("--location L", "default: #{DEFAULTS[:location]}")         { |v| opts[:location] = v }
      o.on("--git-url URL", "default: #{DEFAULTS[:git_url]}")         { |v| opts[:git_url] = v }
      o.on("--revision R", "branch/tag/sha to build")                 { |v| opts[:revision] = v }
      o.on("--destroy", "tear the whole thing down")                  { opts[:destroy] = true }
    end
    parser.parse!
    abort "#{parser}\n\nmissing: --app" unless opts[:app]

    opts
  end

  def call
    opts = options
    return destroy!(opts) if opts[:destroy]

    assert_commit_is_pushed!(opts)
    db = create_database(opts)
    create_app(opts, db)

    url = "https://#{app_host(opts)}"
    Provision.wait_for_health(url, timeout: 1800) # first build + 100k-row seed
    Provision.report_plan(url)

    warn "\nDone. Benchmark it with:\n"
    warn "  ruby bench/collect.rb --platform deploio --tier #{opts[:size]} \\"
    warn "    --url #{url} --db \"postgresqlSingleDbS:6.80\" \\"
    warn "    --rates 2,5,10,15,25,50,75,100,150 --duration 15 --cooldown 5 --retries 1\n\n"
    warn "Tear it down with: ruby bench/provision/deploio.rb --app #{opts[:app]} --destroy"
  end

  # The one-image invariant, enforced rather than hoped for.
  def assert_commit_is_pushed!(opts)
    Provision.step "checking that #{opts[:revision]} is pushed (deploio builds from git, not your disk)"
    local = Provision.run!("git", "rev-parse", opts[:revision], quiet: true).strip
    remote = Provision.run!("git", "ls-remote", "origin", "refs/heads/#{opts[:revision]}", quiet: true)
                      .split(/\s+/).first.to_s

    if remote.empty?
      abort "    origin has no branch '#{opts[:revision]}'. Push it first."
    elsif local != remote
      abort <<~MSG
            local #{opts[:revision]} is #{local[0, 7]} but origin has #{remote[0, 7]}.
            Deploio would build the origin commit, so this target would run DIFFERENT
            code than a Heroku target deployed from your working copy, and the
            comparison would be silently invalid. Push first:  git push origin #{opts[:revision]}
      MSG
    end
    warn "    #{local[0, 7]} — local and origin agree"
  end

  # The cheap single-database product (~5.50 CHF/mo, 1 GB, 20 connections). It
  # measured equal or better than the ~68 CHF/mo dedicated VM, because the app's
  # CPU is the bottleneck, not the database.
  def create_database(opts)
    name = "#{opts[:app]}-db"
    Provision.step "creating postgres database #{name} in #{opts[:location]}"
    ok, out = Provision.try("nctl", "create", "postgresdatabase", name,
                            "-p", opts[:project], "--location", opts[:location],
                            "--wait", "--wait-timeout=20m")
    abort "FAILED to create database:\n#{out}" unless ok || out.include?("already exists")

    name
  end

  # Read the connection string straight into the app's env. It is a live
  # credential: it is never printed, and never written to disk.
  def database_url(opts, db)
    url = Provision.run!("nctl", "get", "postgresdatabase", db, "-p", opts[:project],
                         "--print-connection-string", quiet: true).strip
    abort "could not read the connection string for #{db}" if url.empty?

    url
  end

  def create_app(opts, db)
    Provision.step "creating app #{opts[:app]} (size #{opts[:size]}, dockerfile build, 1 replica)"
    env = Provision::SHARED_ENV.merge(
      "SECRET_KEY_BASE" => Provision.secret_key_base,
      "DATABASE_URL" => database_url(opts, db)
    )

    ok, out = Provision.try("nctl", "create", "application", opts[:app],
                            "-p", opts[:project],
                            "--git-url", opts[:git_url],
                            "--git-revision", opts[:revision],
                            "--dockerfile",
                            "--size", opts[:size],
                            "--replicas", "1",
                            "--port", "8080",
                            "--health-probe-path", "/up",
                            "--env", env.map { |k, v| "#{k}=#{v}" }.join(";"),
                            "--wait", "--wait-timeout=25m")
    abort "FAILED to create app:\n#{out}" unless ok || out.include?("already exists")
  end

  def app_host(opts)
    yaml = Provision.run!("nctl", "get", "application", opts[:app], "-p", opts[:project],
                          "-o", "yaml", quiet: true)
    host = yaml[/cnameTarget:\s*(\S+)/, 1]
    abort "could not determine the app's hostname" unless host

    host
  end

  def destroy!(opts)
    Provision.confirm_destroy!(opts[:app])
    Provision.try("nctl", "delete", "application", opts[:app], "-p", opts[:project], "--force")
    Provision.try("nctl", "delete", "postgresdatabase", "#{opts[:app]}-db",
                  "-p", opts[:project], "--force")
    warn "destroyed #{opts[:app]} and #{opts[:app]}-db"
  end
end

DeploioTarget.call if $PROGRAM_NAME == __FILE__
