Rails.application.routes.draw do
  get  "/up",               to: "bench#up"
  get  "/bench/cpu",        to: "bench#cpu"
  get  "/bench/io",         to: "bench#io"
  get  "/bench/db_read",    to: "bench#db_read"
  match "/bench/db_write",  to: "bench#db_write", via: [:get, :post]
  get  "/bench/db_latency", to: "bench#db_latency"
  get  "/bench/mem",        to: "bench#mem"
  get  "/bench/info",       to: "bench#info"
end
