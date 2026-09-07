defmodule ResidencySchedule.Assistant.Chat.Providers.Anthropic.SSETest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Providers.Anthropic.SSE

  doctest SSE

  describe "parse/2" do
    test "joins a chunk onto the buffered tail" do
      {[], rest} = SSE.parse("", "event: ping\ndata: {\"ty")
      {events, rest} = SSE.parse(rest, "pe\": \"ping\"}\n\n")
      assert events == [%{event: "ping", data: ~s({"type": "ping"})}]
      assert rest == ""
    end

    test "accepts CRLF line endings" do
      {events, ""} = SSE.parse("", "event: a\r\ndata: 1\r\n\r\n")
      assert events == [%{event: "a", data: "1"}]
    end

    test "joins multi-line data with newlines" do
      {events, ""} = SSE.parse("", "data: a\ndata: b\n\n")
      assert events == [%{event: "message", data: "a\nb"}]
    end

    test "skips comments, unknown fields, and empty blocks" do
      {events, ""} = SSE.parse("", ": keepalive\nid: 7\n\n\n\nevent: a\ndata: x\n\n")
      assert events == [%{event: "a", data: "x"}]
    end

    test "strips only one leading space from a value" do
      {events, ""} = SSE.parse("", "data:  two\n\n")
      assert events == [%{event: "message", data: " two"}]
    end
  end

  describe "decode/1" do
    test "rejects invalid JSON" do
      assert SSE.decode(%{event: "x", data: "{nope"}) == {:error, {:bad_event, "{nope"}}
    end

    test "rejects non-object JSON" do
      assert SSE.decode(%{event: "x", data: "[1]"}) == {:error, {:bad_event, "[1]"}}
    end
  end
end
