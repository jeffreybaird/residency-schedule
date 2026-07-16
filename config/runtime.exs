import Config

if System.get_env("PHX_SERVER") do
  config :residency_schedule, ResidencyScheduleWeb.Endpoint, server: true
end

config :residency_schedule, ResidencyScheduleWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Allow Resend in dev when RESEND_API_KEY is set
if config_env() == :dev and System.get_env("RESEND_API_KEY") do
  config :residency_schedule, ResidencySchedule.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")

  config :swoosh, :api_client, Swoosh.ApiClient.Req
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")

  config :residency_schedule, ResidencySchedule.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: System.get_env("DB_SSL", "false") == "true"

  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :residency_schedule, ResidencyScheduleWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 4000],
    secret_key_base: secret_key_base,
    url: [host: System.fetch_env!("PHX_HOST"), scheme: "https", port: 443],
    server: true

  config :residency_schedule,
    access_password: System.fetch_env!("ACCESS_PASSWORD")

  # OpenTelemetry — export traces over OTLP/gRPC to the local Grafana Alloy
  # agent, which batches and forwards them to Grafana Cloud Tempo. The
  # endpoint is optional with a localhost default so a missing Alloy install
  # degrades to failed exports, never a failed boot.
  config :opentelemetry, traces_exporter: :otlp

  config :opentelemetry_exporter,
    otlp_protocol: :grpc,
    otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

  # Structured JSON logs to stdout → journald → Alloy → Grafana Cloud Loki.
  # The Basic formatter lifts :otel_trace_id/:otel_span_id metadata (set by
  # OpentelemetryLoggerMetadata) into top-level trace/span fields, which is
  # what powers trace ↔ log correlation in Grafana.
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: [:request_id, :user_id, :session_id])

  # Resend for transactional email (magic links)
  resend_api_key = System.fetch_env!("RESEND_API_KEY")

  config :residency_schedule, ResidencySchedule.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  config :swoosh, :api_client, Swoosh.ApiClient.Req
end
