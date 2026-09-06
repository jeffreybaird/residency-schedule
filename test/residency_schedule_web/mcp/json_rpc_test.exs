defmodule ResidencyScheduleWeb.MCP.JsonRpcTest do
  use ExUnit.Case, async: true

  alias ResidencyScheduleWeb.MCP.JsonRpc

  doctest JsonRpc

  describe "classify/1" do
    test "string ids are requests" do
      assert {:request, "a", "ping", %{}} =
               JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => "a", "method" => "ping"})
    end

    test "non-map params are ignored" do
      assert {:request, 1, "ping", %{}} =
               JsonRpc.classify(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "ping",
                 "params" => [1]
               })
    end

    test "a float id is invalid" do
      assert :invalid = JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1.5, "method" => "ping"})
    end

    test "missing jsonrpc version is invalid" do
      assert :invalid = JsonRpc.classify(%{"id" => 1, "method" => "ping"})
    end

    test "error responses are responses" do
      assert :response = JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{}})
    end
  end

  describe "code_for/1" do
    test "covers every named code" do
      assert JsonRpc.code_for(:parse_error) == -32_700
      assert JsonRpc.code_for(:invalid_request) == -32_600
      assert JsonRpc.code_for(:internal_error) == -32_603
    end
  end
end
