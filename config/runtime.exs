import Config

if System.get_env("PHX_SERVER") do
  config :residency_schedule, ResidencyScheduleWeb.Endpoint, server: true
end

config :residency_schedule, ResidencyScheduleWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

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
end
