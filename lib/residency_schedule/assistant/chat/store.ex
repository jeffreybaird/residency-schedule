defmodule ResidencySchedule.Assistant.Chat.Store do
  @moduledoc """
  Where a user's chat lives between sessions: one `chat_sessions` row per
  user, replaced after every turn and removed when they start a new chat.

  This is a durable record of what residents asked and were told. It stays
  until the user starts a new chat or their account is deleted.
  """

  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Assistant.Chat.{Codec, Conversation, SavedSession, Transcript}
  alias ResidencySchedule.Repo

  @doc """
  The user's saved chat laid over `base`, a fresh conversation for them.
  Returns `:none` when nothing is saved and `{:error, :unreadable}` when the
  row cannot be read by this version of the code.

  Exempt from doctest — hits the database. See `StoreTest`.
  """
  def load(%User{id: user_id}, %Conversation{} = base) do
    case Repo.one(from s in SavedSession, where: s.user_id == ^user_id, select: s.data) do
      nil -> :none
      data -> Codec.load(data, base)
    end
  end

  @doc """
  Saves the user's chat, replacing whatever was there.

  Exempt from doctest — hits the database. See `StoreTest`.
  """
  def save(%User{id: user_id}, %Conversation{} = conversation, %Transcript{} = transcript) do
    %SavedSession{user_id: user_id}
    |> Ecto.Changeset.change(data: Codec.dump(conversation, transcript))
    |> Repo.insert(on_conflict: {:replace, [:data, :updated_at]}, conflict_target: :user_id)
    |> case do
      {:ok, _saved} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Removes the user's saved chat, if any.

  Exempt from doctest — hits the database. See `StoreTest`.
  """
  def clear(%User{id: user_id}) do
    Repo.delete_all(from s in SavedSession, where: s.user_id == ^user_id)
    :ok
  end
end
