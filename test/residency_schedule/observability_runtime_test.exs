defmodule ResidencySchedule.ObservabilityRuntimeTest do
  use ExUnit.Case, async: false

  @variables ~w(OTEL_ENABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN DATABASE_URL SECRET_KEY_BASE PHX_HOST DEMO_MODE CHAT_ENABLED ACCESS_PASSWORD RESEND_API_KEY)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    System.put_env(%{
      "DATABASE_URL" => "ecto://localhost/test",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "PHX_HOST" => "example.test",
      "DEMO_MODE" => "true"
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "exports are disabled by default in every environment" do
    for env <- [:test, :dev, :prod] do
      refute runtime(env)[:enabled]
    end
  end

  test "only an explicit production opt-in enables export" do
    System.put_env("OTEL_ENABLED", "true")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://otel.example.test")
    System.put_env("OTEL_HUB_TOKEN", "test-token")
    config = runtime(:prod)
    assert config[:enabled]
    assert config[:endpoint] == "https://otel.example.test"
    assert config[:token] == "test-token"
    assert config[:environment] == "production"
    refute runtime(:dev)[:enabled]
    refute runtime(:test)[:enabled]

    for flag <- ["false", "TRUE", "1", ""] do
      System.put_env("OTEL_ENABLED", flag)
      refute runtime(:prod)[:enabled]
    end
  end

  test "enabled export requires both endpoint and token at boot" do
    System.put_env("OTEL_ENABLED", "true")
    assert_raise System.EnvError, fn -> runtime(:prod) end
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://otel.example.test")
    assert_raise System.EnvError, fn -> runtime(:prod) end
  end

  test "rejects credentials containing HTTP header delimiters" do
    System.put_env("OTEL_ENABLED", "true")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://otel.example.test")

    for token <- ["token\rmalicious", "token\nmalicious"] do
      System.put_env("OTEL_HUB_TOKEN", token)
      assert_raise ArgumentError, fn -> runtime(:prod) end
    end
  end

  test "rejects blank credentials and insecure or ambiguous collector URLs" do
    System.put_env("OTEL_ENABLED", "true")
    System.put_env("OTEL_HUB_TOKEN", "test-token")

    for endpoint <- [
          "",
          " ",
          "http://otel.example.test",
          "https:///",
          "https://user:pass@otel.example.test",
          "https://otel.example.test?token=secret",
          "https://otel.example.test#fragment"
        ] do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint)
      assert_raise ArgumentError, fn -> runtime(:prod) end
    end

    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://otel.example.test")

    for token <- ["", "  "] do
      System.put_env("OTEL_HUB_TOKEN", token)
      assert_raise ArgumentError, fn -> runtime(:prod) end
    end
  end

  defp runtime(env) do
    "config/runtime.exs"
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.fetch!(:residency_schedule)
    |> Keyword.get(:observability, [])
  end
end
