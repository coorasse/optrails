# Single image, deployed identically to every platform, so the only variable
# is the platform itself.
FROM ruby:3.4-slim

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    BUNDLE_WITHOUT=development:test

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev postgresql-client fio ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN gem install bundler && bundle install --jobs 4 --retry 3
COPY . .

EXPOSE 8080
# Migrate + (idempotent) seed on boot, then start Puma with autotuned concurrency.
CMD ["bash", "-lc", "bundle exec rails db:prepare && bundle exec rails runner 'load Rails.root.join(\"db/seeds.rb\")' && bundle exec puma -C config/puma.rb"]
