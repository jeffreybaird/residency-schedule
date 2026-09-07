import Config

if System.get_env("PHX_SERVER") do
  config :residency_schedule, ResidencyScheduleWeb.Endpoint, server: true
end

config :residency_schedule, ResidencyScheduleWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if roster_path = System.get_env("ROSTER_PATH") do
  config :residency_schedule, roster_path: roster_path
end

# Allow Resend in dev when RESEND_API_KEY is set
if config_env() == :dev and System.get_env("RESEND_API_KEY") do
  config :residency_schedule, ResidencySchedule.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")

  config :swoosh, :api_client, Swoosh.ApiClient.Req
end

# In dev the chat assistant works whenever a key is present; nothing else
# needs it, so a missing key is not an error.
if config_env() == :dev do
  config :residency_schedule, :chat, api_key: System.get_env("ANTHROPIC_API_KEY")
end

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")

  config :residency_schedule, ResidencySchedule.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: System.get_env("DB_SSL", "false") == "true"

  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  # Bind loopback by default. Nginx proxies from the same host, so nothing needs
  # to reach the endpoint directly — and binding 0.0.0.0 published the app to the
  # internet on its raw port, where a `Host: localhost` request slipped past the
  # force_ssl exclusion in config/prod.exs and served the app over plaintext.
  # Set HTTP_IP=0.0.0.0 to restore the old behaviour if a proxy ever runs off-host.
  http_ip =
    "HTTP_IP"
    |> System.get_env("127.0.0.1")
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()

  config :residency_schedule, ResidencyScheduleWeb.Endpoint,
    http: [ip: http_ip, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base,
    url: [host: System.fetch_env!("PHX_HOST"), scheme: "https", port: 443],
    server: true

  # Public demo deployments serve synthetic data with no login. Resident auth
  # and transactional email are both off, so their secrets are not required.
  demo_mode = System.get_env("DEMO_MODE", "false") == "true"

  config :residency_schedule,
    demo_mode: demo_mode,
    access_password:
      if(demo_mode,
        do: System.get_env("ACCESS_PASSWORD", ""),
        else: System.fetch_env!("ACCESS_PASSWORD")
      )

  # The chat assistant is opt-in per deployment. When on, its key is required
  # so a misconfigured server fails at boot rather than on the first message.
  if System.get_env("CHAT_ENABLED", "false") == "true" do
    config :residency_schedule, :chat, api_key: System.fetch_env!("ANTHROPIC_API_KEY")
  end

  # Resend for transactional email (magic links)
  unless demo_mode do
    config :residency_schedule, ResidencySchedule.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: System.fetch_env!("RESEND_API_KEY")

    config :swoosh, :api_client, Swoosh.ApiClient.Req
  end
end
