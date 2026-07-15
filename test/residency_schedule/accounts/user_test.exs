defmodule ResidencySchedule.Accounts.UserTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Accounts.User

  doctest User

  describe "registration_changeset/2" do
    test "URMC email registers as an approved resident" do
      cs = User.registration_changeset(%User{}, %{email: "jane@urmc.rochester.edu"})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :role) == :resident
      assert Ecto.Changeset.get_field(cs, :approved) == true
    end

    test "non-URMC email registers as an unapproved user" do
      cs = User.registration_changeset(%User{}, %{email: "partner@gmail.com"})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :role) == :user
      assert Ecto.Changeset.get_field(cs, :approved) == false
    end

    test "rejects an invalid email" do
      cs = User.registration_changeset(%User{}, %{email: "not-an-email"})
      refute cs.valid?
      assert {"must be a valid email", _} = cs.errors[:email]
    end

    test "rejects a missing email" do
      cs = User.registration_changeset(%User{}, %{})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:email]
    end
  end

  describe "role_changeset/2" do
    test "allows promoting a non-URMC user to admin" do
      cs = User.role_changeset(%User{email: "partner@gmail.com", role: :user}, %{role: :admin})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :role) == :admin
    end

    test "allows promoting a URMC user to resident" do
      cs =
        User.role_changeset(%User{email: "jane@urmc.rochester.edu", role: :user}, %{
          role: :resident
        })

      assert cs.valid?
    end

    test "rejects the resident role for a non-URMC email" do
      cs = User.role_changeset(%User{email: "partner@gmail.com", role: :user}, %{role: :resident})

      refute cs.valid?
      assert {"resident role requires a URMC email address", _} = cs.errors[:role]
    end

    test "rejects an unknown role" do
      cs = User.role_changeset(%User{email: "jane@urmc.rochester.edu"}, %{role: :superuser})
      refute cs.valid?
      assert cs.errors[:role] != nil
    end

    test "rejects a missing role" do
      cs = User.role_changeset(%User{email: "jane@urmc.rochester.edu", role: :user}, %{role: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:role]
    end
  end

  describe "admin?/1" do
    test "returns true for an admin" do
      assert User.admin?(%User{role: :admin})
    end

    test "returns false for a resident" do
      refute User.admin?(%User{role: :resident})
    end

    test "returns false for a user" do
      refute User.admin?(%User{role: :user})
    end

    test "returns false for nil" do
      refute User.admin?(nil)
    end
  end
end
