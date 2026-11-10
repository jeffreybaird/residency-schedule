defmodule ResidencySchedule.Repo.Migrations.AddFridayPolicyAttestationsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.AddFridayPolicyAttestations

  test "additive migration preserves populated historical classifications and old-shaped inserts" do
    unless Code.ensure_loaded?(AddFridayPolicyAttestations) do
      for path <- Path.wildcard("priv/repo/migrations/*_add_friday_policy_attestations.exs"),
          do: Code.require_file(path)
    end

    {:module, migration} = Code.ensure_loaded(AddFridayPolicyAttestations)

    prefix = "friday_legacy_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")

    Repo.query!(
      "CREATE TABLE activity_source_classifications (id bigint PRIMARY KEY, original_source_id bigint NOT NULL UNIQUE, activity_source_id bigint, namespace text NOT NULL, source_snapshot jsonb NOT NULL, mapping_snapshot jsonb NOT NULL, input_digest text NOT NULL, mapping_id bigint, mapping_revision integer, rule_version text NOT NULL, status text NOT NULL, activity_type_code text, evidence_origin text NOT NULL, inserted_at timestamp, updated_at timestamp)"
    )

    Repo.query!(
      ~s|INSERT INTO activity_source_classifications VALUES (1,2,2,'qgenda','{"source":{"id":2}}','{"policy":"rotation_context_v1"}','old-digest',3,1,'legacy_task_classification_v1','context_required',NULL,'legacy_code','2026-01-01','2026-01-01')|
    )

    original = Repo.query!("SELECT to_jsonb(c) FROM activity_source_classifications c").rows
    for sql <- migration.up_sql(), do: Repo.query!(sql)

    assert Repo.query!("SELECT to_jsonb(c) FROM activity_source_classifications c").rows ==
             original

    assert [[0]] = Repo.query!("SELECT count(*) FROM friday_policy_attestations").rows

    Repo.query!(
      "INSERT INTO activity_source_classifications (id,original_source_id,namespace,source_snapshot,mapping_snapshot,input_digest,mapping_id,mapping_revision,rule_version,status,evidence_origin) VALUES (4,5,'qgenda','{}','{}','new-digest',3,1,'legacy_task_classification_v1','context_required','legacy_code')"
    )

    assert [[2]] = Repo.query!("SELECT count(*) FROM activity_source_classifications").rows
    for sql <- migration.down_sql(), do: Repo.query!(sql)

    assert Repo.query!("SELECT to_jsonb(c) FROM activity_source_classifications c WHERE id=1").rows ==
             original

    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end
end
