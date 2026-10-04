defmodule ResidencySchedule.CiRuntimeCompatibilityTest do
  use ExUnit.Case, async: true

  test "CI and release builds use the same supported BEAM versions as local development" do
    versions =
      ".tool-versions"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [tool, version] = String.split(line)
        {tool, version}
      end)

    [elixir, otp_major] = String.split(versions["elixir"], "-otp-")
    assert Version.match?(elixir, Mix.Project.config()[:elixir])
    assert String.starts_with?(versions["erlang"], otp_major <> ".")

    for workflow <- ["ci.yml", "deploy.yml"] do
      source = File.read!(Path.join(".github/workflows", workflow))

      assert workflow_version(source, "ELIXIR_VERSION") == elixir,
             "#{workflow} must use the local Elixir version required by dependencies"

      assert workflow_version(source, "OTP_VERSION") == versions["erlang"],
             "#{workflow} must use the local patched OTP version"
    end
  end

  defp workflow_version(source, name) do
    [_, version] = Regex.run(Regex.compile!("(?m)^  #{name}: [\"']?([0-9.]+)[\"']?\\s*$"), source)
    version
  end
end
