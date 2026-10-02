defmodule ResidencyScheduleWeb.MCP.BuildTest do
  use ExUnit.Case, async: true

  alias ResidencyScheduleWeb.MCP.Build
  alias ResidencyScheduleWeb.MCP.Tools

  doctest Build

  test "version counts the served tools" do
    assert Build.version() ==
             "#{length(Tools.definitions())} tools @ #{Build.sha()}"
  end
end
