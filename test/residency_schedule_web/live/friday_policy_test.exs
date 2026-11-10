defmodule ResidencyScheduleWeb.AdminLive.FridayPolicyTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.FridayEnrichmentFixtures, as: Fixtures
  alias ResidencySchedule.Repo
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencySchedule.TaskMappings.{FridayEnrichmentRunner, FridayPolicyAttestation}

  @path "/admin/maintenance/friday-policy"

  test "maintenance requires an approved admin session", %{conn: conn} do
    assert conn |> get(@path) |> redirected_to() == "/login"
    user = ScheduleFixtures.unlinked_user()

    assert conn |> Plug.Test.init_test_session(user_id: user.id) |> get(@path) |> redirected_to() ==
             "/"

    denied = Repo.update!(Ecto.Changeset.change(ScheduleFixtures.admin_user(), denied: true))
    denied_conn = Plug.Test.init_test_session(conn, user_id: denied.id)
    assert {:error, {:redirect, %{to: to}}} = live(denied_conn, @path)
    assert to in ["/", "/login"]
  end

  test "admin navigation links the page and no resident evidence is rendered", %{conn: conn} do
    ctx = Fixtures.historical_source()
    conn = Plug.Test.init_test_session(conn, user_id: ctx.admin.id)
    assert {:ok, admin, _} = live(conn, "/admin")
    assert has_element?(admin, "a[href='#{@path}']")
    assert {:ok, view, html} = live(conn, @path)
    assert has_element?(view, "#friday-policy-preview")
    assert has_element?(view, "#friday-policy-status")
    refute has_element?(view, "#friday-policy-apply:not([disabled])")
    refute html =~ ctx.member.name
    refute html =~ ctx.source.raw_staff
    refute html =~ ctx.classification.input_digest
  end

  test "a crafted apply cannot skip preview and client scope never replaces the server reviewed cutoff",
       %{conn: conn} do
    ctx = Fixtures.historical_source()
    conn = Plug.Test.init_test_session(conn, user_id: ctx.admin.id)
    :ok = Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, "maintenance:friday-policy")
    assert {:ok, view, _} = live(conn, @path)

    render_click(view, "apply", %{
      "scope" => %{"max_classification_id" => 999_999},
      "role" => "admin"
    })

    assert Repo.all(FridayPolicyAttestation) == []
    view |> element("#friday-policy-preview") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#friday-policy-apply:not([disabled])")

    later =
      Fixtures.add_historical_source(ctx, ctx.activity.raw_task, Date.add(ctx.activity.date, 1))

    render_click(view, "apply", %{
      "scope" => %{"max_classification_id" => later.classification.id},
      "token" => "forged",
      "actor_id" => ctx.admin.id
    })

    assert await_terminal(ctx.admin).status == :completed

    assert Enum.map(Repo.all(FridayPolicyAttestation), & &1.classification_id) == [
             ctx.classification.id
           ]

    html = render(view)
    refute html =~ ctx.member.name
    refute html =~ ctx.source.raw_staff
  end

  test "an already mounted page rechecks persisted administrator access before preview or apply",
       %{conn: conn} do
    ctx = Fixtures.historical_source()
    conn = Plug.Test.init_test_session(conn, user_id: ctx.admin.id)
    assert {:ok, view, _} = live(conn, @path)
    view |> element("#friday-policy-preview") |> render_click()
    render_async(view, 5_000)
    Repo.update!(Ecto.Changeset.change(ctx.admin, role: :user))
    render_click(view, "apply", %{"role" => "admin", "approved" => "true"})
    assert Repo.all(FridayPolicyAttestation) == []
  end

  defp await_terminal(user) do
    assert {:ok, %{run: run}} = FridayEnrichmentRunner.status(user)

    if run.status == :running do
      receive do
        :friday_policy_enrichment_status_changed -> await_terminal(user)
      after
        5_000 -> flunk("Friday maintenance did not finish")
      end
    else
      run
    end
  end
end
