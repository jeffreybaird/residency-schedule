defmodule ResidencySchedule.TaskMappings.FridayEnrichment do
  @moduledoc "Explicit bounded enrichment of immutable historical contact-night evidence."
  import Ecto.Query
  import Kernel, except: [apply: 2]

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.Schedules.Schedule

  alias ResidencySchedule.TaskMappings.{
    Backfill,
    Classification,
    Classifier,
    FridayPolicyAttestation,
    FridayPolicyEvidence,
    Legacy,
    Mapping,
    Target
  }

  @v1 "legacy_task_classification_v1"
  @scope_keys ~w(kind version policy_fingerprint max_classification_id schedule_id)a
  @fact_fields ~w(namespace source_label lookup_key normalization_version recognized evidence_origin rule_version policy)a

  @doc """
  Reports aggregate eligibility in a finite, read-only classification scope.

      iex> _ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, plan} = ResidencySchedule.TaskMappings.FridayEnrichment.preview(batch_size: 1)
      iex> {plan.counts.eligible, plan.counts.conflicting, plan.scope.kind}
      {1, 0, :historical_friday_policy}
  """
  def preview(options \\ []) do
    with {:ok, opts} <- options(options, [:batch_size, :schedule_id]) do
      max_id = Repo.aggregate(Classification, :max, :id) || 0

      scope = %{
        kind: :historical_friday_policy,
        version: 1,
        policy_fingerprint: FridayPolicyEvidence.fingerprint(),
        max_classification_id: max_id,
        schedule_id: opts.schedule_id
      }

      with {:ok, counts} <- pages(0, scope, opts.batch_size, false, counters(:eligible)) do
        {:ok, %{scope: scope, counts: counts}}
      end
    end
  end

  @doc """
  Revalidates and appends attestations in separately committed bounded pages.

  The scope is a trusted maintenance selection, not a human approval token.
  Failures retain earlier pages; retries never overwrite retained evidence.

      iex> _ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, plan} = ResidencySchedule.TaskMappings.FridayEnrichment.preview()
      iex> {:ok, counts} = ResidencySchedule.TaskMappings.FridayEnrichment.apply(plan.scope, batch_size: 1)
      iex> {counts.attested, counts.conflicting, counts.unchanged}
      {1, 0, 0}
  """
  def apply(scope, options \\ []) do
    with :ok <- validate_scope(scope),
         {:ok, opts} <- options(options, [:batch_size]) do
      pages(0, scope, opts.batch_size, true, counters(:attested))
    end
  end

  defp counters(addition),
    do:
      Map.new(
        [:scanned, addition, :unchanged, :protected, :held, :conflicting, :not_applicable],
        &{&1, 0}
      )

  defp options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      validate_options(Keyword.get(opts, :batch_size, 500), Keyword.get(opts, :schedule_id))
    else
      {:error, :invalid_options}
    end
  end

  defp options(_opts, _allowed), do: {:error, :invalid_options}

  defp validate_options(size, schedule_id)
       when is_integer(size) and size in 1..1000 and
              (is_nil(schedule_id) or (is_integer(schedule_id) and schedule_id > 0)),
       do: {:ok, %{batch_size: size, schedule_id: schedule_id}}

  defp validate_options(_size, _schedule_id), do: {:error, :invalid_options}

  defp validate_scope(scope) when is_map(scope) do
    if Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and valid_scope_fields?(scope),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp validate_scope(_scope), do: {:error, :invalid_scope}

  defp valid_scope_fields?(scope) do
    scope.kind == :historical_friday_policy and scope.version == 1 and
      scope.policy_fingerprint == FridayPolicyEvidence.fingerprint() and
      is_integer(scope.max_classification_id) and scope.max_classification_id >= 0 and
      (is_nil(scope.schedule_id) or (is_integer(scope.schedule_id) and scope.schedule_id > 0))
  end

  defp scoped(scope) do
    query = from c in Classification, where: c.id <= ^scope.max_classification_id

    if scope.schedule_id do
      where(
        query,
        [c],
        fragment("?->'member'->>'schedule_id'", c.source_snapshot) ==
          ^Integer.to_string(scope.schedule_id)
      )
    else
      query
    end
  end

  defp pages(after_id, scope, size, write?, totals) do
    ids =
      scope
      |> scoped()
      |> where([c], c.id > ^after_id)
      |> order_by([c], c.id)
      |> limit(^size)
      |> select([c], c.id)
      |> Repo.all()

    case ids do
      [] -> {:ok, totals}
      _ -> next_page(ids, scope, size, write?, totals)
    end
  end

  defp next_page(ids, scope, size, write?, totals) do
    with {:ok, counts} <- page(ids, scope, write?) do
      updated = Map.merge(totals, counts, fn _key, old, value -> old + value end)
      pages(List.last(ids), scope, size, write?, updated)
    end
  end

  defp page(ids, scope, true) do
    Repo.transaction(fn ->
      Revision.lock()
      process_page(ids, scope, true)
    end)
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError] -> {:error, :write_failed}
  end

  defp page(ids, scope, false), do: {:ok, process_page(ids, scope, false)}

  defp process_page(ids, scope, write?) do
    classes =
      scope
      |> scoped()
      |> where([c], c.id in ^ids)
      |> order_by([c], c.id)
      |> maybe_lock(write?)
      |> Repo.all()

    bundle = load_bundle(classes, write?)

    Enum.reduce(classes, counters(if(write?, do: :attested, else: :eligible)), fn class, counts ->
      status = outcome(class, bundle, write?)
      counts |> increment(:scanned) |> increment(status)
    end)
  end

  defp load_bundle(classes, write?) do
    source_ids = Enum.map(classes, & &1.original_source_id)
    mapping_ids = classes |> Enum.map(& &1.mapping_id) |> Enum.reject(&is_nil/1)
    class_ids = Enum.map(classes, & &1.id)
    graphs = source_graphs(source_ids, write?)

    lookup_keys =
      Enum.flat_map(classes, fn class ->
        case Legacy.friday_policy_fact(class.mapping_snapshot["source_label"]) do
          {:ok, fact} -> [fact.lookup_key]
          _ -> []
        end
      end)

    mappings =
      Mapping
      |> where(
        [m],
        m.id in ^mapping_ids or
          (m.namespace == "qgenda" and m.current and m.lookup_key in ^lookup_keys)
      )
      |> order_by([m], m.id)
      |> maybe_lock(write?)
      |> Repo.all()

    targets =
      Target
      |> where([t], t.mapping_id in ^Enum.map(mappings, & &1.id))
      |> order_by([t], [t.mapping_id, t.activity_type_code])
      |> maybe_lock(write?)
      |> Repo.all()
      |> Enum.group_by(& &1.mapping_id, & &1.activity_type_code)

    attestations =
      FridayPolicyAttestation
      |> where([a], a.classification_id in ^class_ids)
      |> maybe_lock(write?)
      |> Repo.all()

    %{
      graphs: Map.new(graphs, &{&1.source.id, &1}),
      mappings: Map.new(mappings, &{&1.id, &1}),
      current:
        mappings |> Enum.filter(& &1.current) |> Map.new(&{{&1.namespace, &1.lookup_key}, &1}),
      targets: targets,
      attestations: Map.new(attestations, &{&1.classification_id, &1})
    }
  end

  defp source_graphs(ids, write?) do
    from(s in ActivitySource,
      join: a in Activity,
      on: a.id == s.activity_id,
      join: b in ImportBatch,
      on: b.id == s.batch_id,
      join: m in ScheduleResident,
      on: m.id == a.schedule_resident_id,
      join: r in Resident,
      on: r.id == m.resident_id,
      join: schedule in Schedule,
      on: schedule.id == m.schedule_id,
      where: s.id in ^ids,
      order_by: s.id,
      select: %{source: s, activity: a, batch: b, member: m, resident: r, schedule: schedule}
    )
    |> maybe_lock(write?)
    |> Repo.all()
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  defp outcome(class, bundle, write?) do
    with {:ok, fact} <- candidate(class, bundle),
         {:ok, graph, old, targets} <- verified(class, fact, bundle) do
      fields = FridayPolicyEvidence.attestation_fields(class, graph, old, targets)
      existing = Map.get(bundle.attestations, class.id)
      persist_or_compare(existing, fields, write?)
    else
      {:status, status} -> status
    end
  end

  defp candidate(class, bundle) do
    case candidate_fact(class, bundle) do
      {:ok, fact} ->
        cond do
          class.rule_version != @v1 -> :not_applicable
          protected?(class, fact, bundle) -> :protected
          true -> {:ok, fact}
        end
        |> candidate_result()

      {:error, :not_contact_night} ->
        {:status, :not_applicable}
    end
  end

  defp candidate_fact(class, bundle) do
    mapping = Map.get(bundle.mappings, class.mapping_id)

    labels = [
      class.mapping_snapshot["source_label"],
      get_in(class.source_snapshot, ["activity", "raw_task"]),
      if(mapping, do: mapping.source_label)
    ]

    Enum.find_value(labels, {:error, :not_contact_night}, fn label ->
      case Legacy.friday_policy_fact(label) do
        {:ok, fact} -> {:ok, fact}
        _ -> nil
      end
    end)
  end

  defp candidate_result({:ok, _fact} = result), do: result
  defp candidate_result(status), do: {:status, status}

  defp protected?(class, fact, bundle) do
    old = Map.get(bundle.mappings, class.mapping_id)
    current = Map.get(bundle.current, {"qgenda", fact.lookup_key})
    graph = Map.get(bundle.graphs, class.original_source_id)

    Enum.any?([class, old, current], &protected_origin?/1) or
      (not is_nil(graph) and graph.batch.source_kind in ["custom", "reviewed"])
  end

  defp protected_origin?(nil), do: false
  defp protected_origin?(record), do: record.evidence_origin in ["custom", "reviewed"]

  defp verified(class, fact, bundle) do
    graph = Map.get(bundle.graphs, class.original_source_id)
    old = Map.get(bundle.mappings, class.mapping_id)
    targets = Map.get(bundle.targets, class.mapping_id, [])
    current = Map.get(bundle.current, {"qgenda", fact.lookup_key})

    cond do
      is_nil(graph) or is_nil(class.activity_source_id) or is_nil(old) ->
        {:status, :held}

      not original_valid?(class, graph, old, targets, fact) ->
        {:status, :conflicting}

      not current_valid?(current, fact, bundle.targets) ->
        {:status, :conflicting}

      true ->
        {:ok, graph, old, targets}
    end
  end

  defp original_valid?(class, graph, old, targets, fact) do
    old_fact = %{fact | rule_version: @v1, policy: "rotation_context_v1"}
    snapshot = mapping_snapshot(old, targets)

    original_class?(class, old) and original_source?(class, graph, fact) and
      canonical_mapping?(old, targets, old_fact) and
      retained_snapshots?(class, graph, snapshot)
  end

  defp original_class?(class, old) do
    class.namespace == "qgenda" and class.status == "context_required" and
      is_nil(class.activity_type_code) and class.activity_source_id == class.original_source_id and
      class.mapping_revision == old.revision and class.mapping_id == old.id
  end

  defp original_source?(class, graph, fact) do
    graph.source.id == class.original_source_id and graph.batch.source_kind == "qgenda" and
      graph.batch.schedule_id == graph.member.schedule_id and
      graph.activity.raw_task == fact.source_label
  end

  defp retained_snapshots?(class, graph, snapshot) do
    class.mapping_snapshot == snapshot and
      Backfill.source_snapshot(graph) == class.source_snapshot and
      Backfill.input_digest(class.source_snapshot, class.mapping_snapshot) == class.input_digest
  end

  defp mapping_snapshot(mapping, targets) do
    mapping
    |> Map.take(@fact_fields)
    |> Map.merge(%{
      mapping_id: mapping.id,
      mapping_revision: mapping.revision,
      target_codes: targets,
      evidence_snapshot: mapping.evidence_snapshot
    })
    |> Classifier.snapshot()
  end

  defp canonical_mapping?(mapping, targets, fact) do
    Map.take(mapping, @fact_fields) == Map.take(fact, @fact_fields) and targets == fact.targets and
      mapping.evidence_snapshot ==
        Map.new(fact, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp current_valid?(nil, _fact, _targets), do: true

  defp current_valid?(current, fact, target_map) do
    targets = Map.get(target_map, current.id, [])
    old_fact = %{fact | rule_version: @v1, policy: "rotation_context_v1"}
    canonical_mapping?(current, targets, fact) or canonical_mapping?(current, targets, old_fact)
  end

  defp persist_or_compare(existing, fields, _write?) when not is_nil(existing) do
    if Map.take(existing, Map.keys(fields)) == fields, do: :unchanged, else: :conflicting
  end

  defp persist_or_compare(nil, _fields, false), do: :eligible

  defp persist_or_compare(nil, fields, true) do
    Repo.insert!(struct!(FridayPolicyAttestation, fields))
    :attested
  end

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
