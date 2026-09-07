defmodule ResidencySchedule.Assistant.SharedShiftMatrixTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.SharedShiftMatrix

  doctest SharedShiftMatrix

  describe "cells/1" do
    test "empty segments give no cells" do
      assert SharedShiftMatrix.cells([]) == []
    end

    test "off-service segments give no cells" do
      segments = [
        %{
          rotation_type: "vacation",
          start_date: ~D[2026-07-06],
          end_date: ~D[2026-07-12],
          covered_by: nil
        }
      ]

      assert SharedShiftMatrix.cells(segments) == []
    end
  end

  describe "pair_counts/1" do
    test "same date on different services is not shared" do
      cells = %{1 => [{~D[2026-07-06], "oncology"}], 2 => [{~D[2026-07-06], "night_float"}]}
      assert SharedShiftMatrix.pair_counts(cells) == %{}
    end

    test "counts accumulate across days and rotations" do
      cells = %{
        1 => [{~D[2026-07-06], "oncology"}, {~D[2026-07-07], "oncology"}, {~D[2026-07-08], "rei"}],
        2 => [{~D[2026-07-06], "oncology"}, {~D[2026-07-07], "oncology"}, {~D[2026-07-08], "rei"}]
      }

      assert SharedShiftMatrix.pair_counts(cells) == %{
               {1, 2} => %{count: 3, by_rotation: %{"oncology" => 2, "rei" => 1}}
             }
    end

    test "a resident with no cells shares nothing" do
      assert SharedShiftMatrix.pair_counts(%{1 => [], 2 => [{~D[2026-07-06], "oncology"}]}) == %{}
    end
  end
end
