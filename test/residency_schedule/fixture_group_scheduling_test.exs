defmodule ResidencySchedule.FixtureGroupSchedulingTest do
  use ExUnit.Case, async: false

  test "shared database fixtures leave parallel capacity for independent modules" do
    # Run a separate ExUnit scheduler, preserving the caller's test database.
    # The parent owns no Sandbox transaction while the child exercises both cases.
    {output, status} =
      System.cmd(
        "mix",
        [
          "test",
          "--no-compile",
          "test/support/fixtures/shared_fixture_group_probe_test.exs",
          "--seed",
          "0",
          "--max-cases",
          "2"
        ],
        env: [
          {"MIX_ENV", "test"},
          {"RESIDENCY_FIXTURE_GROUP_PROBE", "1"},
          {"MIX_TEST_PARTITION", System.get_env("MIX_TEST_PARTITION")}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "3 tests, 0 failures"
  end
end
