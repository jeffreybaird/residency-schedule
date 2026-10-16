defmodule ResidencySchedule.StagingRuntimeTest do
  use ExUnit.Case, async: false

  @variables ~w(CONFIG_ENVIRONMENT DATABASE_URL SECRET_KEY_BASE PHX_HOST DEMO_MODE ACCESS_PASSWORD RESEND_API_KEY CHAT_ENABLED ANTHROPIC_API_KEY OTEL_ENABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN HTTP_IP PORT POOL_SIZE)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    System.put_env(%{
      "CONFIG_ENVIRONMENT" => "staging",
      "DATABASE_URL" => "ecto://localhost/synthetic_staging",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "PHX_HOST" => "staging.example.test",
      "ACCESS_PASSWORD" => "synthetic-staging-password",
      "PORT" => "4004"
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "staging retains authentication and uses a safe email sink without a Resend key" do
    config = runtime()
    refute config[:demo_mode]
    assert config[:access_password] == "synthetic-staging-password"
    assert config[ResidencySchedule.Mailer][:adapter] == Swoosh.Adapters.Test
    refute config[ResidencySchedule.Mailer][:api_key]
    refute config[:observability][:enabled]
    refute Keyword.get(config, :chat, [])[:enabled]
    assert config[ResidencySchedule.Repo][:url] == "ecto://localhost/synthetic_staging"
    assert config[ResidencyScheduleWeb.Endpoint][:http][:port] == 4004
  end

  test "staging fails boot when the authentication password is missing" do
    System.delete_env("ACCESS_PASSWORD")
    assert_raise System.EnvError, ~r/ACCESS_PASSWORD/, fn -> runtime() end
  end

  test "production still requires Resend credentials and selects the Resend adapter" do
    System.put_env("CONFIG_ENVIRONMENT", "prod")
    assert_raise System.EnvError, ~r/RESEND_API_KEY/, fn -> runtime() end

    System.put_env("RESEND_API_KEY", "synthetic-mail-key")
    config = runtime()
    refute config[:demo_mode]
    assert config[:access_password] == "synthetic-staging-password"
    assert config[ResidencySchedule.Mailer][:adapter] == Swoosh.Adapters.Resend
    assert config[ResidencySchedule.Mailer][:api_key] == "synthetic-mail-key"
  end

  test "public demo still boots without authentication and email credentials" do
    System.put_env("CONFIG_ENVIRONMENT", "demo")
    System.put_env("DEMO_MODE", "true")
    System.delete_env("ACCESS_PASSWORD")
    config = runtime()
    assert config[:demo_mode]
    assert config[:access_password] == ""
    refute config[ResidencySchedule.Mailer]
  end

  defp runtime do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> Keyword.fetch!(:residency_schedule)
  end
end
