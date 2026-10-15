defmodule ResidencyScheduleWeb.HttpProtocolSecurityTest do
  use ExUnit.Case, async: true

  alias ResidencyScheduleWeb.Endpoint

  @config_path Path.expand("../../config/config.exs", __DIR__)
  @runtime_path Path.expand("../../config/runtime.exs", __DIR__)

  for environment <- [:dev, :test, :prod] do
    test "#{environment} configured listeners inherit the HTTP/2 mitigation" do
      config = Config.Reader.read!(@config_path, env: unquote(environment), target: :host)
      endpoint = config |> Keyword.fetch!(:residency_schedule) |> Keyword.fetch!(Endpoint)

      assert endpoint[:adapter] == Bandit.PhoenixAdapter

      assert_listeners_disable_http2(endpoint)
    end
  end

  test "runtime HTTP port configuration preserves the mitigation" do
    config = Config.Reader.read!(@config_path, env: :test, target: :host)
    runtime = Config.Reader.read!(@runtime_path, env: :test, target: :host)

    endpoint =
      config
      |> Config.Reader.merge(runtime)
      |> Keyword.fetch!(:residency_schedule)
      |> Keyword.fetch!(Endpoint)

    assert_listeners_disable_http2(endpoint)
    assert is_integer(get_in(endpoint, [:http, :port]))
  end

  describe "configured Phoenix adapter listener" do
    setup do
      config = Application.fetch_env!(:residency_schedule, Endpoint)

      listener_options =
        config
        |> Keyword.fetch!(:http)
        |> Keyword.merge(ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      adapter_config =
        config
        |> Keyword.put(:otp_app, :residency_schedule)
        |> Keyword.put(:http, listener_options)

      adapter = Keyword.fetch!(config, :adapter)
      [spec] = adapter.child_specs(Endpoint, adapter_config)
      server = start_supervised!(spec)
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

      %{port: port}
    end

    test "rejects HTTP/2 before accepting any frames", %{port: port} do
      socket = connect(port)
      :ok = :gen_tcp.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

      assert :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}
    end

    test "continues serving HTTP/1 requests", %{port: port} do
      socket = connect(port)

      :ok =
        :gen_tcp.send(
          socket,
          "GET /login HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )

      assert receive_headers(socket) =~ "HTTP/1.1 200 OK\r\n"
    end

    test "continues accepting LiveView WebSocket upgrades over HTTP/1", %{port: port} do
      socket = connect(port)

      :ok =
        :gen_tcp.send(socket, [
          "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\n",
          "Host: localhost\r\n",
          "Upgrade: websocket\r\n",
          "Connection: Upgrade\r\n",
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
          "Sec-WebSocket-Version: 13\r\n\r\n"
        ])

      headers = receive_headers(socket)
      assert headers =~ "HTTP/1.1 101 Switching Protocols\r\n"
      assert String.downcase(headers) =~ "upgrade: websocket\r\n"
      assert String.downcase(headers) =~ "sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo=\r\n"
    end
  end

  defp assert_listeners_disable_http2(endpoint) do
    assert is_list(Keyword.fetch!(endpoint, :http))

    for scheme <- [:http, :https], options = endpoint[scheme], options not in [nil, false] do
      assert get_in(options, [:http_2_options, :enabled]) == false,
             "HTTP/2 must be disabled for the configured #{scheme} listener"
    end
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp receive_headers(socket, received \\ "") do
    if String.contains?(received, "\r\n\r\n") do
      received
    else
      assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      receive_headers(socket, received <> data)
    end
  end
end
