class CreateBenchRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :bench_records do |t|
      t.string  :token, null: false
      t.integer :bucket, null: false, default: 0
      t.string  :payload, limit: 512
      t.timestamps
    end
    add_index :bench_records, :token
    add_index :bench_records, :bucket
  end
end
