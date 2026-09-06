defmodule ResidencySchedule.OAuth.PKCETest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.OAuth.PKCE

  doctest PKCE

  describe "verify?/3" do
    test "accepts a matching S256 verifier" do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      assert PKCE.verify?(verifier, PKCE.challenge(verifier), "S256")
    end

    test "rejects a wrong verifier" do
      refute PKCE.verify?("nope", PKCE.challenge("right"), "S256")
    end

    test "rejects the plain method" do
      refute PKCE.verify?("abc", "abc", "plain")
    end

    test "rejects a nil verifier" do
      refute PKCE.verify?(nil, PKCE.challenge("abc"), "S256")
    end
  end
end
