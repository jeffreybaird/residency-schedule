defmodule ResidencySchedule.ReleaseTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Release

  doctest Release

  describe "promote_admin/1" do
    test "promotes an existing user to an approved admin" do
      {:ok, user} = Accounts.create_user(%{email: "operator@gmail.com"})
      refute user.approved

      assert {:ok, admin} = Release.promote_admin("operator@gmail.com")
      assert admin.role == :admin
      assert admin.approved == true
    end

    test "returns an error for an unknown email" do
      assert {:error, :not_found} = Release.promote_admin("nobody@example.com")
    end
  end
end
