defmodule ResidencySchedule.Importer.ResidentLinkerTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.ResidentLinker

  doctest ResidentLinker

  @people [
    %{id: 1, name: "Briar"},
    %{id: 2, name: "Nora K"},
    %{id: 3, name: "Nora Kass"},
    %{id: 4, name: "Rosie"}
  ]

  defp parsed(code, name), do: %{position_code: code, name: name}

  describe "propose/2" do
    test "exact name match, case and whitespace insensitive" do
      [p] = ResidentLinker.propose([parsed("R2-1", "  briar ")], @people)
      assert {p.proposed_id, p.confidence} == {1, :exact}
      assert Enum.map(p.suggestions, & &1.id) == [1]
    end

    test "roster alias match" do
      [p] = ResidentLinker.propose([parsed("R2-1", "Rose")], @people)
      assert {p.proposed_id, p.confidence} == {4, :alias}
    end

    test "single first-name match" do
      [p] = ResidentLinker.propose([parsed("R2-1", "Briar Whitfield")], @people)
      assert {p.proposed_id, p.confidence} == {1, :first_name}
    end

    test "ambiguous first-name match proposes nothing but lists suggestions" do
      [p] = ResidentLinker.propose([parsed("R2-1", "Nora")], @people)
      assert p.proposed_id == nil
      assert p.confidence == :none
      assert Enum.map(p.suggestions, & &1.id) == [2, 3]
    end

    test "no match proposes a new resident" do
      [p] = ResidentLinker.propose([parsed("R1-1", "Zed")], @people)
      assert p.proposed_id == nil
      assert p.confidence == :none
      assert p.suggestions == []
      assert p.position_code == "R1-1"
      assert p.name == "Zed"
    end

    test "with no existing people every row is new" do
      proposals = ResidentLinker.propose([parsed("R1-1", "Briar")], [])
      assert Enum.map(proposals, & &1.proposed_id) == [nil]
    end
  end

  describe "links_from_params/2" do
    setup do
      %{
        proposals: [
          %ResidentLinker{position_code: "R2-1", proposed_id: 1},
          %ResidentLinker{position_code: "R1-1", proposed_id: nil}
        ]
      }
    end

    test "falls back to the proposal for rows not submitted", %{proposals: proposals} do
      assert ResidentLinker.links_from_params(proposals, %{}) == %{"R2-1" => 1, "R1-1" => :new}
    end

    test "\"new\" overrides a proposed link", %{proposals: proposals} do
      assert ResidentLinker.links_from_params(proposals, %{"R2-1" => "new"})["R2-1"] == :new
    end

    test "accepts string and integer ids", %{proposals: proposals} do
      assert ResidentLinker.links_from_params(proposals, %{"R1-1" => "3"})["R1-1"] == 3
      assert ResidentLinker.links_from_params(proposals, %{"R1-1" => 4})["R1-1"] == 4
    end
  end

  describe "validate/3" do
    test "accepts distinct links and genuinely new names" do
      rows = [parsed("R2-1", "Briar"), parsed("R1-1", "Zed")]
      links = %{"R2-1" => 1, "R1-1" => :new}
      assert ResidentLinker.validate(links, rows, @people) == {:ok, links}
    end

    test "rejects a new resident whose name already exists" do
      rows = [parsed("R2-1", "briar")]
      assert {:error, [msg]} = ResidentLinker.validate(%{"R2-1" => :new}, rows, @people)
      assert msg =~ "R2-1"
      assert msg =~ "Briar already exists"
    end

    test "rejects one person linked to two rows" do
      rows = [parsed("R2-1", "Briar"), parsed("R2-2", "Briar B")]
      assert {:error, [msg]} = ResidentLinker.validate(%{"R2-1" => 1, "R2-2" => 1}, rows, @people)
      assert msg =~ "Briar is linked to more than one row: R2-1, R2-2"
    end

    test "names an unknown person id in the shared-link message" do
      rows = [parsed("R2-1", "A"), parsed("R2-2", "B")]

      assert {:error, [msg]} =
               ResidentLinker.validate(%{"R2-1" => 99, "R2-2" => 99}, rows, @people)

      assert msg =~ "Resident #99"
    end

    test "rejects two new rows with the same name" do
      rows = [parsed("R1-1", "Zed"), parsed("R1-2", "zed")]

      assert {:error, [msg]} =
               ResidentLinker.validate(%{"R1-1" => :new, "R1-2" => :new}, rows, @people)

      assert msg =~ "R1-1, R1-2"
    end

    test "collects several problems at once" do
      rows = [parsed("R2-1", "Briar"), parsed("R1-1", "Zed"), parsed("R1-2", "Zed")]
      links = %{"R2-1" => :new, "R1-1" => :new, "R1-2" => :new}
      assert {:error, errors} = ResidentLinker.validate(links, rows, @people)
      assert length(errors) == 2
    end
  end
end
