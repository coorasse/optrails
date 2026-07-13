#!/usr/bin/env ruby
# frozen_string_literal: true

# Provision a complete Heroku benchmark target, from nothing to a URL that
# serves /bench/info.
#
#   ruby bench/provision/heroku.rb --app optrails-hk-2
#   ruby bench/provision/heroku.rb --app optrails-hk-2 --destroy
#
# Deploys the CURRENT local commit by pushing to the app's git remote, so the
# image is whatever you have checked out. Keep that in step with the Deploio
# target, which builds from GitHub -- see bench/provision/deploio.rb.

require "optparse"
require_relative "common"

module HerokuTarget
  module_function

  # A personal Heroku account cannot create apps unless payment-verified, so the
  # app is created under a team that already has billing.
  DEFAULTS = {
    team: "renuo-legacy",
    region: "eu",           # match the Deploio target (Zurich) and the fly/render configs
    dyno: "basic",
    db_plan: "heroku-postgresql:essential-0",
    branch: "master"
  }.freeze

  def options
    opts = DEFAULTS.dup
    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby bench/provision/heroku.rb --app NAME [options]"
      o.on("--app NAME", "Heroku app name (required)")            { |v| opts[:app] = v }
      o.on("--team NAME", "default: #{DEFAULTS[:team]}")          { |v| opts[:team] = v }
      o.on("--region R", "default: #{DEFAULTS[:region]}")         { |v| opts[:region] = v }
      o.on("--dyno SIZE", "default: #{DEFAULTS[:dyno]}")          { |v| opts[:dyno] = v }
      o.on("--db PLAN", "default: #{DEFAULTS[:db_plan]}")         { |v| opts[:db_plan] = v }
      o.on("--branch B", "local branch to deploy")                { |v| opts[:branch] = v }
      o.on("--destroy", "tear the whole thing down")              { opts[:destroy] = true }
    end
    parser.parse!
    abort "#{parser}\n\nmissing: --app" unless opts[:app]

    opts
  end

  def call
    opts = options
    app = opts[:app]
    return destroy!(app) if opts[:destroy]

    create_app(opts)
    add_database(opts)
    configure(app)
    deploy(opts)
    size_dyno(opts)

    url = "https://#{app_host(app)}"
    Provision.wait_for_health(url)
    Provision.report_plan(url)

    warn "\nDone. Benchmark it with:\n"
    warn "  ruby bench/collect.rb --platform heroku --tier Basic \\"
    warn "    --url #{url} --db \"essential-0:5\" \\"
    warn "    --rates 2,5,10,15,25,50,75,100,150 --duration 15 --cooldown 5 --retries 1\n\n"
    warn "Tear it down with: ruby bench/provision/heroku.rb --app #{app} --destroy"
  end

  def create_app(opts)
    Provision.step "creating app #{opts[:app]} (#{opts[:region]}, container stack, team #{opts[:team]})"
    ok, out = Provision.try("heroku", "create", opts[:app], "--team", opts[:team],
                            "--region", opts[:region], "--stack", "container")
    if !ok && out.include?("already taken")
      warn "    already exists, reusing"
    elsif !ok
      abort "FAILED to create app:\n#{out}"
    end
  end

  def add_database(opts)
    Provision.step "provisioning #{opts[:db_plan]}"
    ok, out = Provision.try("heroku", "addons:create", opts[:db_plan], "--app", opts[:app], "--wait")
    warn "    #{ok ? 'provisioned' : "note: #{out.lines.first&.strip}"}"
  end

  # Rails 8 resolves secret_key_base lazily, from env_config, on the FIRST
  # request. Without it the app builds, boots, and then 500s on request one --
  # which reads like a platform fault and is not.
  def configure(app)
    Provision.step "setting config vars"
    env = Provision::SHARED_ENV.merge("SECRET_KEY_BASE" => Provision.secret_key_base)
    Provision.run!("heroku", "config:set", *env.map { |k, v| "#{k}=#{v}" }, "--app", app, quiet: true)
    warn "    #{Provision::SHARED_ENV.keys.join(', ')}, SECRET_KEY_BASE"
  end

  # The container stack builds from heroku.yml at the REPO ROOT. Pushing to the
  # app's own remote keeps this independent of origin.
  def deploy(opts)
    Provision.step "deploying #{opts[:branch]} (docker build, then release migrates + seeds)"
    abort "heroku.yml missing from the repo root — the container stack needs it there" \
      unless File.exist?(File.join(Provision::ROOT, "heroku.yml"))

    remote = "heroku-#{opts[:app]}"
    Provision.try("git", "remote", "remove", remote)
    Provision.run!("git", "remote", "add", remote, "https://git.heroku.com/#{opts[:app]}.git", quiet: true)
    Provision.run!("git", "push", remote, "#{opts[:branch]}:main")
  end

  def size_dyno(opts)
    Provision.step "scaling web to #{opts[:dyno]} x1 (autoscale off, one instance)"
    Provision.run!("heroku", "ps:type", "web=#{opts[:dyno]}", "--app", opts[:app], quiet: true)
  end

  def app_host(app)
    info = Provision.run!("heroku", "apps:info", "--app", app, "--json", quiet: true)
    URI(JSON.parse(info).dig("app", "web_url")).host
  end

  def destroy!(app)
    Provision.confirm_destroy!(app)
    Provision.run!("heroku", "apps:destroy", app, "--confirm", app)
    Provision.try("git", "remote", "remove", "heroku-#{app}")
    warn "destroyed #{app} (the Postgres add-on goes with it)"
  end
end

HerokuTarget.call if $PROGRAM_NAME == __FILE__
