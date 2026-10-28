defmodule ResidencySchedule.MigrationDoctests do
  @moduledoc """
  Compiles migrations under `priv/repo/migrations/` so their modules can be
  tested and doctested.

  Migrations are not on the compile path. `Code.require_file/1` loads them in
  memory, but `doctest` and `Code.fetch_docs/1` read documentation from a beam
  on the code path, and `mix test` compiles with `docs: false`. This module
  compiles each matching file with docs, writes its beam into a test-only
  directory under the build path and adds that directory to the code path.

  It runs once from `test/test_helper.exs`, before any test file is loaded, so
  the same module is never required or compiled twice concurrently by
  separate test files.
  """

  @doc """
  Compiles every migration matching `glob` (relative to the project root) into
  `Mix.Project.build_path()/migration_doctests` and adds that directory to the
  code path. Returns the list of compiled modules.

  The `:ignore_module_conflict` and `:docs` compiler options are set for the
  compilation only and restored afterwards. Each beam is written to a temporary
  name and renamed into place so a concurrent partition never reads a partial
  file.
  """
  def compile!(glob) do
    beam_dir = Path.join(Mix.Project.build_path(), "migration_doctests")
    File.mkdir_p!(beam_dir)

    modules =
      with_compiler_options([ignore_module_conflict: true, docs: true], fn ->
        for path <- Path.wildcard(glob),
            {module, binary} <- Code.compile_file(path) do
          write_beam(beam_dir, module, binary)
          module
        end
      end)

    true = Code.append_path(beam_dir)
    modules
  end

  defp with_compiler_options(options, fun) do
    previous = for {key, _value} <- options, do: {key, Code.get_compiler_option(key)}
    for {key, value} <- options, do: Code.put_compiler_option(key, value)

    try do
      fun.()
    after
      for {key, value} <- previous, do: Code.put_compiler_option(key, value)
    end
  end

  defp write_beam(beam_dir, module, binary) do
    beam = Path.join(beam_dir, "#{module}.beam")
    temporary = "#{beam}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, binary)
    File.rename!(temporary, beam)
  end
end
