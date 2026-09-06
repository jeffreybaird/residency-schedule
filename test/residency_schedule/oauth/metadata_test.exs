defmodule ResidencySchedule.OAuth.MetadataTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.OAuth.Metadata

  doctest Metadata

  describe "resource_matches?/2" do
    test "ignores a trailing slash on the resource" do
      assert Metadata.resource_matches?("https://s.example/mcp/", "https://s.example")
    end

    test "rejects a different path" do
      refute Metadata.resource_matches?("https://s.example/other", "https://s.example")
    end

    test "rejects a nil resource" do
      refute Metadata.resource_matches?(nil, "https://s.example")
    end
  end

  describe "authorization_server/1" do
    test "advertises registration and both grant types" do
      doc = Metadata.authorization_server("https://s.example/")
      assert doc.registration_endpoint == "https://s.example/oauth/register"
      assert doc.grant_types_supported == ["authorization_code", "refresh_token"]
      assert doc.issuer == "https://s.example"
    end
  end
end
