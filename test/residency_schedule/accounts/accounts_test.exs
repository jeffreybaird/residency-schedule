defmodule ResidencySchedule.AccountsTest do
  use ResidencySchedule.DataCase, async: true

  import Swoosh.TestAssertions

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Accounts.User

  describe "create_user/1" do
    test "creates an approved resident for URMC email and does not notify admin" do
      {:ok, user} = Accounts.create_user(%{email: "jane@urmc.rochester.edu"})
      assert user.email == "jane@urmc.rochester.edu"
      assert user.role == :resident
      assert user.approved == true

      refute_email_sent(to: [{nil, "jeffreybaird@hey.com"}])
    end

    test "creates an unapproved user-role account for non-URMC email and notifies admin" do
      {:ok, user} = Accounts.create_user(%{email: "jane@gmail.com"})
      assert user.email == "jane@gmail.com"
      assert user.role == :user
      assert user.approved == false

      assert_email_sent(
        to: [{nil, "jeffreybaird@hey.com"}],
        subject: "New approval request — jane@gmail.com"
      )
    end

    test "rejects duplicate email" do
      {:ok, _} = Accounts.create_user(%{email: "dup@urmc.rochester.edu"})
      assert {:error, changeset} = Accounts.create_user(%{email: "dup@urmc.rochester.edu"})
      assert errors_on(changeset)[:email] != nil
    end

    test "rejects blank email" do
      assert {:error, changeset} = Accounts.create_user(%{email: ""})
      assert errors_on(changeset)[:email] != nil
    end
  end

  describe "find_or_create_user_by_email/1" do
    test "creates a new user when none exists" do
      {:ok, user} = Accounts.find_or_create_user_by_email("new@urmc.rochester.edu")
      assert user.email == "new@urmc.rochester.edu"
    end

    test "returns existing user when email already taken" do
      {:ok, original} = Accounts.create_user(%{email: "existing@urmc.rochester.edu"})
      {:ok, found} = Accounts.find_or_create_user_by_email("existing@urmc.rochester.edu")
      assert found.id == original.id
    end
  end

  describe "get_user_by_email/1" do
    test "finds user by email" do
      {:ok, user} = Accounts.create_user(%{email: "find@urmc.rochester.edu"})
      assert Accounts.get_user_by_email("find@urmc.rochester.edu").id == user.id
    end

    test "returns nil for unknown email" do
      assert Accounts.get_user_by_email("nope@urmc.rochester.edu") == nil
    end
  end

  describe "set_password/2 and authenticate_by_password/2" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "pw@urmc.rochester.edu"})
      %{user: user}
    end

    test "sets a password that can be verified", %{user: user} do
      {:ok, updated} = Accounts.set_password(user, "mysecretpass")
      assert updated.password_hash != nil
      assert {:ok, _} = Accounts.authenticate_by_password("pw@urmc.rochester.edu", "mysecretpass")
    end

    test "rejects wrong password", %{user: user} do
      Accounts.set_password(user, "mysecretpass")

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_password("pw@urmc.rochester.edu", "wrong")
    end

    test "rejects when no password set", %{user: user} do
      assert Accounts.has_password?(user) == false

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_password("pw@urmc.rochester.edu", "anything")
    end

    test "rejects unknown email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_password("unknown@test.com", "pass")
    end
  end

  describe "has_password?/1" do
    test "false for user without password" do
      refute Accounts.has_password?(%User{password_hash: nil})
    end

    test "true for user with password" do
      assert Accounts.has_password?(%User{password_hash: "$2b$12$something"})
    end
  end

  describe "home_resident" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "home@urmc.rochester.edu"})
      %{schedule_id: _sid} = seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      %{user: user, resident: resident}
    end

    test "set_home_resident/2 persists home_resident_id", %{user: user, resident: resident} do
      {:ok, updated} = Accounts.set_home_resident(user, resident.id)
      assert updated.home_resident_id == resident.id
    end

    test "clear_home_resident/1 sets home_resident_id to nil", %{user: user, resident: resident} do
      {:ok, with_home} = Accounts.set_home_resident(user, resident.id)
      {:ok, cleared} = Accounts.clear_home_resident(with_home)
      assert cleared.home_resident_id == nil
    end
  end

  describe "approval" do
    test "list_pending_users/0 returns unapproved users" do
      {:ok, _} = Accounts.create_user(%{email: "pending@gmail.com"})
      {:ok, _} = Accounts.create_user(%{email: "approved@urmc.rochester.edu"})

      pending = Accounts.list_pending_users()
      assert length(pending) == 1
      assert hd(pending).email == "pending@gmail.com"
    end

    test "approve_user/1 sets approved to true and sends approval email" do
      {:ok, user} = Accounts.create_user(%{email: "toapprove@gmail.com"})
      assert user.approved == false

      # Drain the admin notification from create_user
      assert_email_sent(to: [{nil, "jeffreybaird@hey.com"}])

      {:ok, approved} = Accounts.approve_user(user)
      assert approved.approved == true

      assert_email_sent(subject: "You've been approved — Residency Schedule")
    end

    test "revoke_user/1 sets approved to false" do
      {:ok, user} = Accounts.create_user(%{email: "revoke@urmc.rochester.edu"})
      assert user.approved == true

      {:ok, revoked} = Accounts.revoke_user(user)
      assert revoked.approved == false
    end

    test "revoke_user/1 refuses to revoke an admin" do
      {:ok, user} = Accounts.create_user(%{email: "boss@gmail.com"})
      {:ok, admin} = Accounts.set_role(user, :admin)

      assert {:error, :admin_cannot_be_revoked} = Accounts.revoke_user(admin)
      assert Accounts.get_user!(admin.id).approved == true
    end
  end

  describe "tour" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "tour@urmc.rochester.edu"})
      %{user: user}
    end

    test "new users have tour_completed as false", %{user: user} do
      assert user.tour_completed == false
    end

    test "complete_tour/1 marks tour as completed", %{user: user} do
      {:ok, updated} = Accounts.complete_tour(user)
      assert updated.tour_completed == true
    end

    test "reset_tour/1 resets tour_completed to false", %{user: user} do
      {:ok, completed} = Accounts.complete_tour(user)
      assert completed.tour_completed == true

      {:ok, reset} = Accounts.reset_tour(completed)
      assert reset.tour_completed == false
    end
  end

  describe "magic link tokens" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "token@urmc.rochester.edu"})
      %{user: user}
    end

    test "validate returns the user for an active token", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)
      assert is_binary(token_string)

      {:ok, validated_user} = Accounts.validate_magic_link_token(token_string)
      assert validated_user.id == user.id
    end

    test "validate does not consume the token", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)

      # A scanner pre-fetching the link validates it repeatedly...
      {:ok, _} = Accounts.validate_magic_link_token(token_string)
      {:ok, _} = Accounts.validate_magic_link_token(token_string)

      # ...and the real user can still consume it afterward.
      assert {:ok, consumed_user} = Accounts.consume_magic_link_token(token_string)
      assert consumed_user.id == user.id
    end

    test "validate rejects an invalid token" do
      assert {:error, :invalid_or_expired} = Accounts.validate_magic_link_token("nonexistent")
    end

    test "validate rejects an expired token", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)
      expire_token(token_string)

      assert {:error, :invalid_or_expired} = Accounts.validate_magic_link_token(token_string)
    end

    test "validate rejects an already-consumed token", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)
      {:ok, _} = Accounts.consume_magic_link_token(token_string)

      assert {:error, :invalid_or_expired} = Accounts.validate_magic_link_token(token_string)
    end

    test "consume returns the user and marks the token used", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)

      {:ok, consumed_user} = Accounts.consume_magic_link_token(token_string)
      assert consumed_user.id == user.id
    end

    test "consume can only be used once", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)
      {:ok, _} = Accounts.consume_magic_link_token(token_string)
      assert {:error, :invalid_or_expired} = Accounts.consume_magic_link_token(token_string)
    end

    test "consume rejects an invalid token" do
      assert {:error, :invalid_or_expired} = Accounts.consume_magic_link_token("nonexistent")
    end

    test "consume rejects an expired token", %{user: user} do
      {:ok, token_string} = Accounts.generate_magic_link_token(user)
      expire_token(token_string)

      assert {:error, :invalid_or_expired} = Accounts.consume_magic_link_token(token_string)
    end
  end

  describe "change_password/3" do
    setup do
      {:ok, user} = Accounts.create_user(%{email: "pw-change@urmc.rochester.edu"})
      %{user: user}
    end

    test "sets a password when none exists, ignoring the current password", %{user: user} do
      assert {:ok, updated} = Accounts.change_password(user, "", "brandnewpass1")
      assert {:ok, _} = Accounts.authenticate_by_password(updated.email, "brandnewpass1")
    end

    test "changes the password when the current one matches", %{user: user} do
      {:ok, user} = Accounts.set_password(user, "originalpass1")

      assert {:ok, updated} = Accounts.change_password(user, "originalpass1", "brandnewpass1")
      assert {:ok, _} = Accounts.authenticate_by_password(updated.email, "brandnewpass1")
    end

    test "rejects a wrong current password", %{user: user} do
      {:ok, user} = Accounts.set_password(user, "originalpass1")

      assert {:error, :invalid_current_password} =
               Accounts.change_password(user, "wrongpass", "brandnewpass1")

      assert {:ok, _} = Accounts.authenticate_by_password(user.email, "originalpass1")
    end

    test "rejects a new password shorter than 8 characters", %{user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.change_password(user, "", "short")

      assert errors_on(changeset)[:password] != nil
    end

    test "rejects an empty new password", %{user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.change_password(user, "", "")
      assert errors_on(changeset)[:password] != nil
    end
  end

  describe "set_role/2" do
    test "promotes an unapproved user to admin and approves them" do
      {:ok, user} = Accounts.create_user(%{email: "partner@gmail.com"})
      refute user.approved

      assert {:ok, admin} = Accounts.set_role(user, :admin)
      assert admin.role == :admin
      assert admin.approved == true
    end

    test "demotes a resident to the user role" do
      {:ok, resident} = Accounts.create_user(%{email: "jane@urmc.rochester.edu"})
      assert {:ok, user} = Accounts.set_role(resident, :user)
      assert user.role == :user
    end

    test "promotes a URMC user back to resident" do
      {:ok, resident} = Accounts.create_user(%{email: "jane@urmc.rochester.edu"})
      {:ok, demoted} = Accounts.set_role(resident, :user)

      assert {:ok, promoted} = Accounts.set_role(demoted, :resident)
      assert promoted.role == :resident
    end

    test "rejects the resident role for a non-URMC email" do
      {:ok, user} = Accounts.create_user(%{email: "partner@gmail.com"})

      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.set_role(user, :resident)
      assert errors_on(changeset)[:role] != nil
    end

    test "refuses to demote the last admin" do
      {:ok, user} = Accounts.create_user(%{email: "onlyadmin@gmail.com"})
      {:ok, admin} = Accounts.set_role(user, :admin)

      assert {:error, :last_admin} = Accounts.set_role(admin, :user)
    end

    test "allows demoting an admin when another admin remains" do
      {:ok, first} = Accounts.create_user(%{email: "first-admin@gmail.com"})
      {:ok, second} = Accounts.create_user(%{email: "second-admin@gmail.com"})
      {:ok, first_admin} = Accounts.set_role(first, :admin)
      {:ok, _second_admin} = Accounts.set_role(second, :admin)

      assert {:ok, demoted} = Accounts.set_role(first_admin, :user)
      assert demoted.role == :user
    end

    test "keeping the last admin as admin is allowed" do
      {:ok, user} = Accounts.create_user(%{email: "onlyadmin@gmail.com"})
      {:ok, admin} = Accounts.set_role(user, :admin)

      assert {:ok, still_admin} = Accounts.set_role(admin, :admin)
      assert still_admin.role == :admin
    end
  end

  describe "list_admins/0" do
    test "returns only admins ordered by email" do
      {:ok, resident} = Accounts.create_user(%{email: "resident@urmc.rochester.edu"})
      {:ok, b_user} = Accounts.create_user(%{email: "b-admin@gmail.com"})
      {:ok, a_user} = Accounts.create_user(%{email: "a-admin@gmail.com"})
      {:ok, _} = Accounts.set_role(b_user, :admin)
      {:ok, _} = Accounts.set_role(a_user, :admin)

      admins = Accounts.list_admins()
      assert Enum.map(admins, & &1.email) == ["a-admin@gmail.com", "b-admin@gmail.com"]
      refute resident.id in Enum.map(admins, & &1.id)
    end

    test "returns an empty list when there are no admins" do
      assert Accounts.list_admins() == []
    end
  end

  defp expire_token(token_string) do
    Repo.update_all(
      from(t in ResidencySchedule.Accounts.MagicLinkToken, where: t.token == ^token_string),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)]
    )
  end
end
