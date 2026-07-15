defmodule ResidencySchedule.Repo.Migrations.PromoteInitialAdminTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Repo.Migrations.PromoteInitialAdmin

  # Migrations live in priv/ and are not on the compile path — load the file so
  # the real upsert SQL is callable, skipping it if it is already defined.
  unless Code.ensure_loaded?(PromoteInitialAdmin) do
    Code.require_file("priv/repo/migrations/20260715160000_promote_initial_admin.exs")
  end

  @admin_email "jeffreybaird@hey.com"

  describe "promote_sql/0" do
    test "creates the operator account as an approved admin when it does not exist" do
      refute Accounts.get_user_by_email(@admin_email)

      Repo.query!(PromoteInitialAdmin.promote_sql())

      user = Accounts.get_user_by_email(@admin_email)
      assert user.role == :admin
      assert user.approved == true
    end

    test "promotes and approves an existing pending account without duplicating it" do
      {:ok, existing} = Accounts.create_user(%{email: @admin_email})
      assert existing.role == :user
      refute existing.approved

      Repo.query!(PromoteInitialAdmin.promote_sql())

      user = Accounts.get_user_by_email(@admin_email)
      assert user.id == existing.id
      assert user.role == :admin
      assert user.approved == true
    end

    test "matches an existing account case-insensitively (citext)" do
      {:ok, existing} = Accounts.create_user(%{email: "JeffreyBaird@Hey.com"})

      Repo.query!(PromoteInitialAdmin.promote_sql())

      assert [only] = Accounts.list_admins()
      assert only.id == existing.id
    end
  end
end
