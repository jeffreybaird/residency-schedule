defmodule ResidencySchedule.ObservabilityTest do
  use ExUnit.Case, async: false

  alias OtlpShipper.Metrics.Definition
  alias ResidencySchedule.Observability

  @tag :tmp_dir
  test "deployment version accepts only packaged complete commit hashes", %{tmp_dir: directory} do
    path = Path.join(directory, "deploy_sha")
    assert Observability.deployment_version(path) == "unknown"
    sha = String.duplicate("a1", 20)
    File.write!(path, sha <> "\n")
    assert Observability.deployment_version(path) == sha

    for invalid <- ["", "abcdef", String.duplicate("z", 40), sha <> " private-data"] do
      File.write!(path, invalid)
      assert Observability.deployment_version(path) == "unknown"
    end
  end

  test "deployment packages its actual commit before compiling assets and release" do
    workflow = File.read!(".github/workflows/deploy.yml")
    [before_assets | _] = String.split(workflow, "mix assets.deploy", parts: 2)
    assert before_assets =~ "GITHUB_SHA"
    assert before_assets =~ "priv/deploy_sha"
  end

  setup do
    previous = Application.get_env(:residency_schedule, :observability)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:residency_schedule, :observability, previous),
        else: Application.delete_env(:residency_schedule, :observability)
    end)
  end

  test "export supervision is opt-in" do
    Application.delete_env(:residency_schedule, :observability)
    assert Observability.children() == []
    Application.put_env(:residency_schedule, :observability, enabled: false)
    assert Observability.children() == []

    config = [
      enabled: true,
      endpoint: "https://otel.example.test",
      token: "fake",
      environment: "production"
    ]

    Application.put_env(:residency_schedule, :observability, config)
    assert [{Observability, ^config}] = Observability.children()
  end

  test "request attributes allow only bounded method and status" do
    conn = Plug.Test.conn("GET", "/resident/private?token=secret") |> Map.put(:status, 200)

    assert Observability.request_attributes(%{conn: conn, secret: "private"}) == %{
             "http.request.method" => "GET",
             "http.response.status_code" => 200
           }

    for method <- ~w(GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH) do
      assert Observability.request_attributes(%{conn: %{conn | method: method}})[
               "http.request.method"
             ] == method
    end

    for status <- [nil, "200", 99, 600] do
      assert Observability.request_attributes(%{conn: %{conn | method: "secret", status: status}}) ==
               %{
                 "http.request.method" => "_OTHER"
               }
    end

    assert Observability.request_attributes(%{}) == %{"http.request.method" => "_OTHER"}
  end

  test "existing metric definitions remain tagless bounded aggregates" do
    metrics = Observability.metrics()

    existing_metrics =
      Enum.reject(metrics, fn metric ->
        match?([:phoenix, :live_view | _], metric.event_name) or
          metric.event_name == [:browser, :live_view, :round_trip]
      end)

    assert length(existing_metrics) == 11
    assert Enum.all?(existing_metrics, &(&1.tags == []))

    assert Enum.any?(
             metrics,
             &match?(%Telemetry.Metrics.Counter{event_name: [:phoenix, :endpoint, :stop]}, &1)
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.Distribution{event_name: [:phoenix, :endpoint, :stop]},
               &1
             )
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.Distribution{event_name: [:residency_schedule, :repo, :query]},
               &1
             )
           )

    assert Enum.any?(
             metrics,
             &match?(%Telemetry.Metrics.LastValue{event_name: [:vm, :memory]}, &1)
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.LastValue{event_name: [:vm, :total_run_queue_lengths]},
               &1
             )
           )

    refute Enum.any?(metrics, &match?(%Telemetry.Metrics.Summary{}, &1))

    for %Telemetry.Metrics.Distribution{} = metric <- metrics do
      assert [_ | _] = metric.reporter_options[:buckets]
    end
  end

  test "LiveView operation durations have only a bounded view tag" do
    metrics =
      Observability.metrics()
      |> Enum.filter(&match?([:phoenix, :live_view | _], &1.event_name))

    assert length(metrics) == 4

    for operation <- [:mount, :handle_params, :handle_event, :render] do
      metric = Enum.find(metrics, &(&1.event_name == [:phoenix, :live_view, operation, :stop]))
      assert %Telemetry.Metrics.Distribution{} = metric
      assert metric.measurement != nil
      assert metric.tags == [:view]
      assert metric.unit == :millisecond
      assert metric.reporter_options[:buckets] == [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]

      {:ok, [definition]} = Definition.new([metric])

      for metadata <- [
            %{socket: %Phoenix.LiveView.Socket{view: ResidencyScheduleWeb.CompareLive.Index}},
            %{socket: %Phoenix.LiveView.Socket{view: "private-resident-value"}},
            %{socket: %Phoenix.LiveView.Socket{view: nil}},
            %{socket: nil},
            %{}
          ] do
        assert Definition.sample(definition, %{duration: 1}, metadata) == :skip
      end
    end
  end

  test "browser round trip duration has only bounded view and operation tags" do
    [metric] =
      Enum.filter(
        Observability.metrics(),
        &(&1.event_name == [:browser, :live_view, :round_trip])
      )

    assert %Telemetry.Metrics.Distribution{} = metric
    assert metric.name == [:browser, :live_view, :round_trip, :duration]
    assert metric.measurement == :duration_ms
    assert metric.tags == [:view, :operation]
    assert metric.unit == :millisecond
    assert metric.reporter_options[:buckets] == [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]
    {:ok, [definition]} = Definition.new([metric])

    for metadata <- [
          %{view: "resident/private", operation: "event"},
          %{view: "calendar", operation: "restore_prefs"},
          %{view: nil, operation: "event"},
          %{}
        ] do
      assert Definition.sample(definition, %{duration_ms: 12}, metadata) == :skip
    end
  end

  test "resident lifecycle duration uses a fixed view label without widening browser ingestion" do
    metric =
      Enum.find(
        Observability.metrics(),
        &(&1.event_name == [:phoenix, :live_view, :mount, :stop])
      )

    assert metric.tag_values.(%{
             socket: %Phoenix.LiveView.Socket{view: ResidencyScheduleWeb.ResidentLive.Show},
             params: %{"id" => "PRIVATE"}
           }) == %{view: "resident"}

    assert {:error, :invalid_sample} =
             Observability.browser_latency_sample(%{
               "view" => "resident",
               "operation" => "event",
               "duration_ms" => 1
             })
  end

  test "schedule comparison phase and mismatch count are allowlisted and preserve results" do
    alias ResidencySchedule.Observability.Tracing
    assert Tracing.phase(:schedule_compare, fn -> 1 end) == 1
    assert Tracing.count(:mismatches, 0) == :ok
    assert Tracing.count(:mismatches, 7) == :ok
  end
end
