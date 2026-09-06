defmodule ResidencySchedule.Assistant.ResidentResolverTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.Assistant.ResidentResolver
  alias ResidencySchedule.Importer.NameNormalizer
  alias ResidencySchedule.Residents.ScheduleResident

  doctest ResidentResolver

  @residents [
    %ScheduleResident{id: 1, name: "Nora"},
    %ScheduleResident{id: 2, name: "Nora Kass"},
    %ScheduleResident{id: 3, name: "Nora Yale"},
    %ScheduleResident{id: 4, name: "Katie Z"},
    %ScheduleResident{id: 5, name: "Katy G"}
  ]

  describe "match/2" do
    test "exact full name wins over first-name ambiguity" do
      assert {:ok, %{id: 1}} = ResidentResolver.match(@residents, "Nora")
    end

    test "first name ambiguity is reported with candidates" do
      residents = Enum.reject(@residents, &(&1.id == 1))
      assert {:error, {:ambiguous, many}} = ResidentResolver.match(residents, "nora")
      assert Enum.map(many, & &1.id) == [2, 3]
    end

    test "prefix of the full name" do
      assert {:ok, %{id: 3}} = ResidentResolver.match(@residents, "nora y")
    end

    test "ambiguous prefix" do
      assert {:error, {:ambiguous, _}} = ResidentResolver.match(@residents, "kat")
    end

    test "roster alias maps to the canonical name" do
      aliases = NameNormalizer.aliases()

      case Enum.find(aliases, fn {alias_name, canonical} -> alias_name != canonical end) do
        nil ->
          flunk("fixture roster has no aliases")

        {alias_name, canonical} ->
          residents = [%ScheduleResident{id: 9, name: canonical}]
          assert {:ok, %{id: 9}} = ResidentResolver.match(residents, alias_name)
      end
    end

    test "unknown name and non-string" do
      assert {:error, :not_found} = ResidentResolver.match(@residents, "Zelda")
      assert {:error, :not_found} = ResidentResolver.match(@residents, nil)
    end
  end

  describe "resolve/2" do
    test "resolves within a schedule" do
      %{schedule: schedule, tiff: tiff} = seed_mini_schedule()
      assert {:ok, %{id: id}} = ResidentResolver.resolve("tiff", schedule.id)
      assert id == tiff.id
      assert {:error, :not_found} = ResidentResolver.resolve("Briar", schedule.id)
    end
  end
end
