defmodule ResidencySchedule.Assistant.Chat.StoreTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Assistant.Chat.{Conversation, Message, SavedSession, Store, Transcript}
  alias ResidencyScheduleWeb.MCP.Toolbox

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        email: "store-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    %{user: user, base: Conversation.new(toolbox: Toolbox, user: user)}
  end

  defp chat(base, text) do
    conversation = %{base | messages: [Message.user(text), Message.assistant([{:text, "Ok."}])]}
    transcript = Transcript.new() |> Transcript.add(%{kind: :user, text: text})
    {conversation, transcript}
  end

  test "there is nothing to load for a new user", %{user: user, base: base} do
    assert Store.load(user, base) == :none
  end

  test "a saved chat loads back", %{user: user, base: base} do
    {conversation, transcript} = chat(base, "Hi")
    assert :ok = Store.save(user, conversation, transcript)

    assert {:ok, loaded, loaded_transcript} = Store.load(user, base)
    assert loaded.messages == conversation.messages
    assert loaded_transcript == transcript
  end

  test "saving again replaces the previous chat", %{user: user, base: base} do
    {first, first_transcript} = chat(base, "First")
    {second, second_transcript} = chat(base, "Second")
    :ok = Store.save(user, first, first_transcript)
    :ok = Store.save(user, second, second_transcript)

    assert {:ok, %{messages: [%{parts: [text: "Second"]} | _]}, _} = Store.load(user, base)
    assert Repo.aggregate(SavedSession, :count) == 1
  end

  test "clear removes the chat and is fine when there is none", %{user: user, base: base} do
    {conversation, transcript} = chat(base, "Hi")
    :ok = Store.save(user, conversation, transcript)

    assert :ok = Store.clear(user)
    assert Store.load(user, base) == :none
    assert :ok = Store.clear(user)
  end

  test "a row this version cannot read is reported", %{user: user, base: base} do
    Repo.insert!(%SavedSession{user_id: user.id, data: %{"version" => 99}})
    assert Store.load(user, base) == {:error, :unreadable}
  end

  test "the chat goes with the user", %{user: user, base: base} do
    {conversation, transcript} = chat(base, "Hi")
    :ok = Store.save(user, conversation, transcript)

    Repo.delete!(user)
    assert Repo.aggregate(SavedSession, :count) == 0
  end
end
