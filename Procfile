web: bundle exec puma -C config/puma.rb
release: bundle exec rails db:prepare && bundle exec rails runner 'load Rails.root.join("db/seeds.rb")'
