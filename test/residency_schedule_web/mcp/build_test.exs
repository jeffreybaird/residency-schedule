defmodule ResidencyScheduleWeb.MCP.BuildTest do
  use ExUnit.Case, async: true

  alias ResidencyScheduleWeb.MCP.Build

  doctest Build

  test "version counts the served tools" do
    assert Build.version() ==
             "#{length(ResidencyScheduleWeb.MCP.Tools.definitions())} tools @ #{Build.sha()}"
  end
end
