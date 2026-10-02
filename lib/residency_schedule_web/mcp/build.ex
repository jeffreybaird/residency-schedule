defmodule ResidencyScheduleWeb.MCP.Build do
  @moduledoc """
  Identifies which build of the server a client is talking to. The commit
  is captured at compile time from `GITHUB_SHA` (set by the deploy workflow)
  and reads `"dev"` for local builds.
  """

  alias ResidencyScheduleWeb.MCP.Tools
  @sha System.get_env("GITHUB_SHA", "dev") |> String.slice(0, 7)

  @doc """
  Short commit sha of this build, or `"dev"`.

      iex> ResidencyScheduleWeb.MCP.Build.sha() |> is_binary()
      true
  """
  def sha, do: @sha

  @doc """
  Version string advertised in `serverInfo`: the tool count plus the build sha,
  so a stale client can tell at a glance whether it is out of date.

      iex> ResidencyScheduleWeb.MCP.Build.version() =~ ~r/^\\d+ tools @ [0-9a-f]{7}|dev$/
      true
  """
  def version do
    "#{length(Tools.definitions())} tools @ #{@sha}"
  end
end
