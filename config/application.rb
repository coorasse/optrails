require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module OptRails
  class Application < Rails::Application
    config.load_defaults 8.0
    config.api_only = true
    config.eager_load = ENV.fetch("RAILS_ENV", "development") == "production"

    # Keep the DB pool at least as large as the Puma thread count so
    # pool-checkout latency reflects the platform, not our own starvation.
    config.after_initialize do
      pool = (ENV["RAILS_MAX_THREADS"] || 5).to_i
      db = ActiveRecord::Base.connection_db_config.configuration_hash.dup
      db[:pool] = [pool, db[:pool].to_i].max
    end
  end
end
