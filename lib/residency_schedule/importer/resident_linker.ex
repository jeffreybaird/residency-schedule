defmodule ResidencySchedule.Importer.ResidentLinker do
  @moduledoc """
  Proposes which existing resident (person) each row of a newly uploaded
  schedule belongs to, so an admin can confirm the links before the import is
  written. A resident is one database record across academic years, so a wrong
  link would merge two people's careers and a missed link would split one.

  Matching order per row: exact name, roster alias, first name. A row with no
  match, or with several first-name matches, is proposed as a new resident.
  """

  alias ResidencySchedule.Importer.NameNormalizer

  defstruct position_code: nil, name: nil, proposed_id: nil, confidence: :none, suggestions: []

  @type link :: :new | pos_integer()

  @doc """
  Builds one proposal per parsed resident against the given people (any maps
  or structs with `:id` and `:name`).

      iex> parsed = [%{position_code: "R2-1", name: "Briar"}, %{position_code: "R1-1", name: "Zed"}]
      iex> people = [%{id: 7, name: "Briar"}, %{id: 8, name: "Nora"}]
      iex> [briar, zed] = ResidencySchedule.Importer.ResidentLinker.propose(parsed, people)
      iex> {briar.proposed_id, briar.confidence}
      {7, :exact}
      iex> {zed.proposed_id, zed.confidence}
      {nil, :none}
  """
  def propose(parsed_residents, people) do
    Enum.map(parsed_residents, &propose_one(&1, people))
  end

  @doc """
  Turns submitted form values (`%{position_code => "new" | person id}`) into
  links, falling back to each proposal's default where a row was not submitted.

      iex> proposals = [
      ...>   %ResidencySchedule.Importer.ResidentLinker{position_code: "R2-1", proposed_id: 7},
      ...>   %ResidencySchedule.Importer.ResidentLinker{position_code: "R1-1", proposed_id: nil}
      ...> ]
      iex> ResidencySchedule.Importer.ResidentLinker.links_from_params(proposals, %{"R1-1" => "9"})
      %{"R2-1" => 7, "R1-1" => 9}
  """
  def links_from_params(proposals, params) do
    Map.new(proposals, fn proposal ->
      {proposal.position_code, link_for(proposal, Map.get(params, proposal.position_code))}
    end)
  end

  @doc """
  Checks a set of links against the parsed rows and existing people. Returns
  `{:ok, links}` or `{:error, messages}` when a new resident would collide
  with an existing name, two rows share a person, or two new rows share a name.

      iex> parsed = [%{position_code: "R2-1", name: "Briar"}]
      iex> people = [%{id: 7, name: "Briar"}]
      iex> ResidencySchedule.Importer.ResidentLinker.validate(%{"R2-1" => 7}, parsed, people)
      {:ok, %{"R2-1" => 7}}
  """
  def validate(links, parsed_residents, people) do
    errors =
      new_name_collisions(links, parsed_residents, people) ++
        shared_person_links(links, people) ++
        duplicate_new_names(links, parsed_residents)

    case errors do
      [] -> {:ok, links}
      errors -> {:error, errors}
    end
  end

  @doc """
  Normalizes a name for comparison: trimmed, lowercased, single spaces.

      iex> ResidencySchedule.Importer.ResidentLinker.normalize_name("  Katie   Z ")
      "katie z"
  """
  def normalize_name(name) do
    name
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  # --- proposing ---

  defp propose_one(parsed, people) do
    base = %__MODULE__{position_code: parsed.position_code, name: parsed.name}

    with :none <- match_level(people, parsed.name, :exact, &exact?/2),
         :none <- match_level(people, parsed.name, :alias, &alias?/2),
         :none <- match_level(people, parsed.name, :first_name, &first_name?/2) do
      base
    else
      {:one, person, confidence} ->
        %{base | proposed_id: person.id, confidence: confidence, suggestions: [person]}

      {:many, matches} ->
        %{base | suggestions: matches}
    end
  end

  defp match_level(people, name, confidence, predicate) do
    case Enum.filter(people, &predicate.(&1.name, name)) do
      [] -> :none
      [person] -> {:one, person, confidence}
      many -> {:many, many}
    end
  end

  defp exact?(person_name, name), do: normalize_name(person_name) == normalize_name(name)

  defp alias?(person_name, name) do
    Map.get(NameNormalizer.aliases(), normalize_name(name)) == normalize_name(person_name)
  end

  defp first_name?(person_name, name), do: first_token(person_name) == first_token(name)

  defp first_token(name), do: name |> normalize_name() |> String.split(" ") |> hd()

  # --- links from params ---

  defp link_for(proposal, nil), do: proposal.proposed_id || :new
  defp link_for(_proposal, "new"), do: :new
  defp link_for(_proposal, id) when is_integer(id), do: id
  defp link_for(_proposal, id) when is_binary(id), do: String.to_integer(id)

  # --- validation ---

  defp new_name_collisions(links, parsed_residents, people) do
    parsed_residents
    |> Enum.filter(&(Map.get(links, &1.position_code) == :new))
    |> Enum.flat_map(fn parsed ->
      case Enum.find(people, &exact?(&1.name, parsed.name)) do
        nil ->
          []

        person ->
          [
            "#{parsed.position_code}: a resident named #{person.name} already exists; link the row to them"
          ]
      end
    end)
  end

  defp shared_person_links(links, people) do
    links
    |> Enum.reject(fn {_code, link} -> link == :new end)
    |> Enum.group_by(fn {_code, id} -> id end, fn {code, _id} -> code end)
    |> Enum.filter(fn {_id, codes} -> length(codes) > 1 end)
    |> Enum.map(fn {id, codes} ->
      "#{person_name(people, id)} is linked to more than one row: #{Enum.join(Enum.sort(codes), ", ")}"
    end)
  end

  defp duplicate_new_names(links, parsed_residents) do
    parsed_residents
    |> Enum.filter(&(Map.get(links, &1.position_code) == :new))
    |> Enum.group_by(&normalize_name(&1.name), & &1.position_code)
    |> Enum.filter(fn {_name, codes} -> length(codes) > 1 end)
    |> Enum.map(fn {_name, codes} ->
      "rows #{Enum.join(Enum.sort(codes), ", ")} would each create a new resident with the same name"
    end)
  end

  defp person_name(people, id) do
    case Enum.find(people, &(&1.id == id)) do
      nil -> "Resident ##{id}"
      person -> person.name
    end
  end
end
