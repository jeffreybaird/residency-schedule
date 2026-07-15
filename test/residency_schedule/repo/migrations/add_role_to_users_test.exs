defmodule ResidencySchedule.Repo.Migrations.AddRoleToUsersTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Repo
  alias ResidencySchedule.Repo.Migrations.AddRoleToUsers

  # Migrations live in priv/ and are not on the compile path — Ecto only loads
  # them when they are pending. Load the file here so the real backfill SQL is
  # callable, skipping it if a pending-migration run already defined the module.
  unless Code.ensure_loaded?(AddRoleToUsers) do
    Code.require_file("priv/repo/migrations/20260715130000_add_role_to_users.exs")
  end

  # Inserts a raw user row bypassing changesets so we can seed the pre-backfill
  # state (every account defaulting to the "user" role, as after the column is
  # first added) regardless of email domain.
  defp insert_user(email) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "users",
        [%{email: email, role: "user", approved: false, inserted_at: now, updated_at: now}],
        returning: [:id]
      )

    id
  end

  defp role_of(id) do
    %{rows: [[role]]} = Repo.query!("SELECT role FROM users WHERE id = $1", [id])
    role
  end

  describe "backfill_up_sql/0" do
    test "classifies operator, URMC, and other accounts by email" do
      operator = insert_user("brendablennon@gmail.com")
      urmc = insert_user("jane@urmc.rochester.edu")
      other = insert_user("partner@gmail.com")

      Repo.query!(AddRoleToUsers.backfill_up_sql())

      assert role_of(operator) == "admin"
      assert role_of(urmc) == "resident"
      assert role_of(other) == "user"
    end

    test "matches operator and URMC emails case-insensitively (citext)" do
      operator = insert_user("JLBaird87@Gmail.com")
      urmc = insert_user("Bob@URMC.Rochester.EDU")

      Repo.query!(AddRoleToUsers.backfill_up_sql())

      assert role_of(operator) == "admin"
      assert role_of(urmc) == "resident"
    end

    test "does not treat a non-URMC address containing the domain as a URMC email" do
      spoof = insert_user("attacker@urmc.rochester.edu.evil.com")

      Repo.query!(AddRoleToUsers.backfill_up_sql())

      assert role_of(spoof) == "user"
    end
  end

  describe "backfill_down_sql/0" do
    test "resets every account to the user role" do
      operator = insert_user("brendablennon@gmail.com")
      urmc = insert_user("jane@urmc.rochester.edu")

      Repo.query!(AddRoleToUsers.backfill_up_sql())
      Repo.query!(AddRoleToUsers.backfill_down_sql())

      assert role_of(operator) == "user"
      assert role_of(urmc) == "user"
    end
  end
end
