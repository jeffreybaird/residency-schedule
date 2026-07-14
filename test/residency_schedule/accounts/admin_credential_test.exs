defmodule ResidencySchedule.Accounts.AdminCredentialTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Accounts.AdminCredential

  doctest AdminCredential

  describe "password_changeset/2" do
    test "hashes a valid password and discards the plaintext" do
      cs = AdminCredential.password_changeset(%AdminCredential{}, %{password: "supersecret1"})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :password) == nil
      assert Bcrypt.verify_pass("supersecret1", Ecto.Changeset.get_change(cs, :password_hash))
    end

    test "rejects a password shorter than 8 characters and does not hash" do
      cs = AdminCredential.password_changeset(%AdminCredential{}, %{password: "short"})

      refute cs.valid?
      assert {"should be at least %{count} character(s)", _} = cs.errors[:password]
      assert Ecto.Changeset.get_change(cs, :password_hash) == nil
    end

    test "rejects a missing password" do
      cs = AdminCredential.password_changeset(%AdminCredential{}, %{})

      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:password]
    end

    test "rejects an empty password" do
      cs = AdminCredential.password_changeset(%AdminCredential{}, %{password: ""})

      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:password]
    end
  end

  describe "valid_password?/2" do
    test "returns true for the matching password" do
      credential = %AdminCredential{password_hash: Bcrypt.hash_pwd_salt("supersecret1")}
      assert AdminCredential.valid_password?(credential, "supersecret1")
    end

    test "returns false for a non-matching password" do
      credential = %AdminCredential{password_hash: Bcrypt.hash_pwd_salt("supersecret1")}
      refute AdminCredential.valid_password?(credential, "wrongpassword")
    end

    test "returns false when no hash is set" do
      refute AdminCredential.valid_password?(%AdminCredential{password_hash: nil}, "anything")
    end
  end
end
