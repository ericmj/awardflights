import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :awardflights, AwardflightsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jV75LnWEzJXK6cl0zGx7fwrOinoOIq5x4RimuTqBRuLOJUu6PUiGMqnPdAYSf0gA",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Use test-specific CSV files in tmp/ to avoid clobbering production data
config :awardflights,
  results_file: "tmp/test_results.csv",
  failed_file: "tmp/test_failed_requests.csv",
  history_file: "tmp/test_request_history.csv",
  rate_limits_file: "tmp/test_rate_limits.csv"
