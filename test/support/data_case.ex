defmodule ResidencySchedule.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ResidencySchedule.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ResidencySchedule.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ResidencySchedule.DataCase
    end
  end

  setup tags do
    ResidencySchedule.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ResidencySchedule.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Seeds the test database with a sample fixture CSV.
  Defaults to the 2023-2024 schedule; pass `2026` for the 2026-2027 fixture.
  Returns the import result map `%{schedule_id: id, residents: n, rotations: m}`.
  """
  def seed_schedule(year \\ 2023) do
    fixture =
      if year == 2023,
        do: "test/fixtures/sample_schedule.csv",
        else: "test/fixtures/sample_schedule_2026.csv"

    csv = File.read!(fixture)
    {:ok, result, _warnings} = ResidencySchedule.Importer.ScheduleImporter.import_csv(csv)
    result
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
