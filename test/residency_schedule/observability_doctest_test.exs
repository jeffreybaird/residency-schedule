defmodule ResidencySchedule.ObservabilityDoctestTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.Observability.RequestHandler

  doctest ResidencySchedule.Observability
  doctest ResidencySchedule.Observability.RequestHandler

  test "missing or invalid request durations are ignored without requiring exporter state" do
    for measurements <- [%{}, %{duration: nil}, %{duration: "12"}, %{duration: -1}] do
      assert :ok =
               RequestHandler.handle_event(
                 [:phoenix, :endpoint, :stop],
                 measurements,
                 %{secret: "private"},
                 %{}
               )
    end
  end
end
