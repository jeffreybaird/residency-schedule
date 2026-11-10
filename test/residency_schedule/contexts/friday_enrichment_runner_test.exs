defmodule ResidencySchedule.TaskMappings.FridayEnrichmentRunnerTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.FridayEnrichmentFixtures, as: Fixtures
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencySchedule.TaskMappings.{FridayEnrichmentRunner, FridayPolicyAttestation}

  @topic "maintenance:friday-policy"

  test "persisted approved admin can preview read-only with an opaque server-held token" do
    ctx = Fixtures.historical_source()
    assert {:ok, preview} = FridayEnrichmentRunner.preview(ctx.admin)
    assert is_binary(preview.token)
    assert preview.counts.eligible == 1
    assert Enum.sort(Map.keys(preview)) == [:counts, :token]
    assert Repo.all(FridayPolicyAttestation) == []
    assert {:ok, status} = FridayEnrichmentRunner.status(ctx.admin)
    assert status.preview == preview
    assert status.run.operation == :preview
    assert status.run.status == :completed

    assert Map.keys(status.run) |> Enum.sort() ==
             Enum.sort([:operation, :status, :started_at, :finished_at, :counts, :error])
  end

  test "all service gates reject unapproved, denied, non-admin, revoked and forged-role callers" do
    user = ScheduleFixtures.unlinked_user()
    admin = ScheduleFixtures.admin_user()
    denied = Repo.update!(Ecto.Changeset.change(ScheduleFixtures.admin_user(), denied: true))

    unapproved =
      Repo.update!(Ecto.Changeset.change(ScheduleFixtures.admin_user(), approved: false))

    Repo.update!(Ecto.Changeset.change(admin, role: :user))
    forged = %{user | role: :admin, approved: true, denied: false}

    for actor <- [nil, user, admin, denied, unapproved, forged] do
      assert {:error, :forbidden} = FridayEnrichmentRunner.status(actor)
      assert {:error, :forbidden} = FridayEnrichmentRunner.preview(actor)
      assert {:error, :forbidden} = FridayEnrichmentRunner.start(actor, "forged")
    end
  end

  test "only the preview owner can consume the current token and explicit review is required" do
    ctx = Fixtures.historical_source()
    other = ScheduleFixtures.admin_user()
    assert {:error, :invalid_preview} = FridayEnrichmentRunner.start(ctx.admin, "never-reviewed")
    assert {:ok, preview} = FridayEnrichmentRunner.preview(ctx.admin)
    assert {:ok, %{preview: nil}} = FridayEnrichmentRunner.status(other)
    assert {:error, :invalid_preview} = FridayEnrichmentRunner.start(other, preview.token)

    assert {:error, :invalid_preview} =
             FridayEnrichmentRunner.start(ctx.admin, %{scope: %{max_classification_id: 999_999}})

    assert {:ok, replacement} = FridayEnrichmentRunner.preview(ctx.admin)
    refute replacement.token == preview.token
    assert {:error, :invalid_preview} = FridayEnrichmentRunner.start(ctx.admin, preview.token)
    assert Repo.all(FridayPolicyAttestation) == []
  end

  test "revocation after preview defeats an otherwise valid token and stale actor struct" do
    ctx = Fixtures.historical_source()
    assert {:ok, preview} = FridayEnrichmentRunner.preview(ctx.admin)
    Repo.update!(Ecto.Changeset.change(ctx.admin, role: :user))
    assert {:error, :forbidden} = FridayEnrichmentRunner.start(ctx.admin, preview.token)
    assert Repo.all(FridayPolicyAttestation) == []
  end

  test "node-owned apply publishes final aggregate counts and retains last apply through later previews" do
    ctx = Fixtures.historical_source()
    :ok = Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, @topic)
    assert {:ok, preview} = FridayEnrichmentRunner.preview(ctx.admin)

    assert {:ok, %{status: :running, operation: :apply}} =
             FridayEnrichmentRunner.start(ctx.admin, preview.token)

    run = await_terminal(ctx.admin)
    assert run.status == :completed
    assert run.counts.attested == 1
    assert run.error == nil
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
    refute DateTime.before?(run.finished_at, run.started_at)
    assert {:error, :invalid_preview} = FridayEnrichmentRunner.start(ctx.admin, preview.token)
    assert {:ok, _} = FridayEnrichmentRunner.preview(ctx.admin)
    assert {:ok, %{last_run: ^run}} = FridayEnrichmentRunner.status(ctx.admin)
  end

  test "write failure reports a fixed public error without SQL or resident detail" do
    ctx = Fixtures.historical_source()
    :ok = Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, @topic)
    assert {:ok, preview} = FridayEnrichmentRunner.preview(ctx.admin)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_friday_ui_probe() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'PRIVATE_FRIDAY_UI_SQL_FAILURE'; RETURN NEW; END; $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_friday_ui_probe BEFORE INSERT ON friday_policy_attestations FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_friday_ui_probe()"
    )

    try do
      assert {:ok, _} = FridayEnrichmentRunner.start(ctx.admin, preview.token)
      run = await_terminal(ctx.admin)
      assert run.status == :failed
      assert run.error == :write_failed
      refute inspect(run) =~ "PRIVATE_FRIDAY_UI_SQL_FAILURE"
      refute inspect(run) =~ ctx.member.name
    after
      Repo.query!("DROP TRIGGER reject_friday_ui_probe ON friday_policy_attestations")
    end
  end

  defp await_terminal(user) do
    assert {:ok, %{run: run}} = FridayEnrichmentRunner.status(user)

    if run.status == :running do
      receive do
        :friday_policy_enrichment_status_changed -> await_terminal(user)
      after
        5_000 -> flunk("Friday enrichment did not publish terminal status")
      end
    else
      run
    end
  end
end
