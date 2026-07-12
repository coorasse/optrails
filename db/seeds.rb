# Seed enough rows that db_read hits an index over a non-trivial table,
# not a table that fits entirely in a page cache warm-up.
require "securerandom"

target = (ENV["SEED_ROWS"] || 100_000).to_i
existing = BenchRecord.count
to_add = target - existing
puts "[seed] existing=#{existing} target=#{target} adding=#{[to_add,0].max}"

batch = []
(1..[to_add, 0].max).each do |i|
  batch << {
    token: SecureRandom.hex(12),
    bucket: rand(1000),
    payload: SecureRandom.hex(64),
    created_at: Time.now, updated_at: Time.now
  }
  if batch.size >= 5000
    BenchRecord.insert_all(batch)
    batch.clear
    print "."
  end
end
BenchRecord.insert_all(batch) unless batch.empty?
puts "\n[seed] done total=#{BenchRecord.count}"
