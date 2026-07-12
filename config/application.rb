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

    # The DB pool must stay >= the Puma thread count so pool-checkout latency
    # reflects the platform, not our own starvation. That is enforced where the
    # pool is actually built, in config/database.yml.
  end
end
