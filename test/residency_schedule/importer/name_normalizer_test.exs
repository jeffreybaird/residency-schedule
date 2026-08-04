defmodule ResidencySchedule.Importer.NameNormalizerTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.Importer.NameNormalizer

  setup do
    original = Application.get_env(:residency_schedule, :roster_path)

    on_exit(fn ->
      Application.put_env(:residency_schedule, :roster_path, original)
    end)

    :ok
  end

  describe "normalize/3" do
    test "returns the canonical name for a rostered {year, code}" do
      assert NameNormalizer.normalize(2023, "R4-1", "Briar Whitfield") == "Briar"
    end

    test "falls back to the trimmed raw name for an unrostered {year, code}" do
      assert NameNormalizer.normalize(2099, "R1-1", "  Someone New ") == "Someone New"
    end
  end

  describe "get_canonical_schedule_numbers/1" do
    test "returns year/code pairs in ascending year order" do
      assert NameNormalizer.get_canonical_schedule_numbers("Quinn") ==
               [{2023, "R1-1"}, {2024, "R2-6"}, {2025, "R3-3"}, {2026, "R4-7"}]
    end

    test "returns an empty list for an unknown name" do
      assert NameNormalizer.get_canonical_schedule_numbers("Nobody") == []
    end
  end

  describe "all_canonical_names/0" do
    test "lists each rostered resident exactly once" do
      names = NameNormalizer.all_canonical_names()
      assert length(names) == length(Enum.uniq(names))
      assert "Sasha" in names
    end
  end

  describe "aliases/0" do
    test "maps each lowercase alias to its lowercase canonical name" do
      aliases = NameNormalizer.aliases()
      assert aliases["rose"] == "rosie"
      assert aliases["aleksandra"] == "sasha"
      assert aliases["aleksa"] == "sasha"
    end
  end

  describe "roster consistency" do
    test "forward and reverse mappings agree" do
      for name <- NameNormalizer.all_canonical_names(),
          {year, code} <- NameNormalizer.get_canonical_schedule_numbers(name) do
        assert NameNormalizer.normalize(year, code, "raw") == name
      end
    end
  end

  describe "roster loading" do
    test "missing roster file yields the raw-name fallback everywhere" do
      Application.put_env(:residency_schedule, :roster_path, "test/fixtures/no_such_roster.csv")

      assert NameNormalizer.normalize(2023, "R4-1", "Raw Name") == "Raw Name"
      assert NameNormalizer.get_canonical_schedule_numbers("Quinn") == []
      assert NameNormalizer.all_canonical_names() == []
      assert NameNormalizer.aliases() == %{}
    end

    test "rows without an alias column entry are skipped by the alias map" do
      refute Map.has_key?(NameNormalizer.aliases(), "quinn")
    end
  end
end
