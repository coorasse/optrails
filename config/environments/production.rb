require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = true
  config.consider_all_requests_local = false
  config.log_level = ENV.fetch("LOG_LEVEL", "info").to_sym
  config.logger = ActiveSupport::Logger.new($stdout)
  config.active_record.dump_schema_after_migration = false
  # No SSL redirect: we terminate TLS at the platform edge and benchmark
  # the app, not the redirect.
  config.force_ssl = false
end
