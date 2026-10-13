defmodule ResidencyScheduleWeb.LiveSerializerTest do
  use ExUnit.Case, async: false

  alias Phoenix.Socket.{Broadcast, Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer
  alias ResidencySchedule.CountingJSON
  alias ResidencyScheduleWeb.{Endpoint, LiveSerializer}

  setup do
    previous = Application.get_env(:phoenix, :json_library)
    Application.put_env(:phoenix, :json_library, CountingJSON)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix, :json_library, previous),
        else: Application.delete_env(:phoenix, :json_library)
    end)
  end

  test "text and binary replies/messages retain the exact Phoenix V2 protocol and encode once" do
    for payload <- [%{private: "PRIVATE_SERIALIZER_SENTINEL"}, {:binary, <<0, 255, 10>>}],
        message <- [
          %Message{topic: "lv:private", event: "diff", payload: payload, join_ref: "1", ref: "2"},
          %Reply{topic: "lv:private", status: :ok, payload: payload, join_ref: "1", ref: "2"}
        ] do
      expected = JSONSerializer.encode!(message)
      Process.put(:diagnostic_encode_calls, 0)
      assert LiveSerializer.encode!(message) == expected
      assert Process.get(:diagnostic_encode_calls) == if(is_map(payload), do: 1, else: 0)
    end
  end

  test "broadcast fastlane and incoming text/binary decode remain byte-for-byte compatible" do
    for payload <- [%{private: "PRIVATE_SERIALIZER_SENTINEL"}, {:binary, <<1, 2, 3>>}] do
      message = %Broadcast{topic: "lv:private", event: "private", payload: payload}
      assert LiveSerializer.fastlane!(message) == JSONSerializer.fastlane!(message)
    end

    text = Jason.encode!(["1", "2", "lv:private", "event", %{secret: "private"}])

    assert LiveSerializer.decode!(text, opcode: :text) ==
             JSONSerializer.decode!(text, opcode: :text)

    binary = <<0, 1, 1, 2, 1, "1", "2", "lv", "e", 0, 255>>

    assert LiveSerializer.decode!(binary, opcode: :binary) ==
             JSONSerializer.decode!(binary, opcode: :binary)
  end

  test "encoding errors retain the original exception and never retry the encoder" do
    message = %Message{topic: "lv:private", event: "diff", payload: %{not_encodable: self()}}
    expected = capture_error(fn -> JSONSerializer.encode!(message) end)
    Process.put(:diagnostic_encode_calls, 0)
    assert capture_error(fn -> LiveSerializer.encode!(message) end) == expected
    assert Process.get(:diagnostic_encode_calls) == 1
  end

  test "both live transports preserve V1 support and install the V2 wrapper" do
    {"/live", _socket, opts} = Enum.find(Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

    for transport <- [:websocket, :longpoll] do
      serializers = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:serializer)
      assert {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"} in serializers
      assert {LiveSerializer, "~> 2.0.0"} in serializers
    end
  end

  defp capture_error(fun) do
    fun.()
    flunk("expected an encoding error")
  rescue
    error -> {error.__struct__, Exception.message(error)}
  end
end
