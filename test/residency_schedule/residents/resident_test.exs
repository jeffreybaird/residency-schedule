defmodule ResidencySchedule.Residents.ResidentTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Residents.Resident

  doctest Resident

  describe "changeset/2" do
    test "is valid with a name and a calendar token" do
      cs = Resident.changeset(%Resident{}, %{name: "Briar", calendar_token: "tok-1"})
      assert cs.valid?
    end

    test "requires a calendar token" do
      cs = Resident.changeset(%Resident{}, %{name: "Briar"})
      refute cs.valid?
      assert %{calendar_token: ["can't be blank"]} = errors_on(cs)
    end

    test "requires a name" do
      cs = Resident.changeset(%Resident{}, %{calendar_token: "tok-1"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
