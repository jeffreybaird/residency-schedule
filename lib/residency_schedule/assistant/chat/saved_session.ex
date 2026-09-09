defmodule ResidencySchedule.Assistant.Chat.SavedSession do
  @moduledoc """
  One user's chat as stored in the database: the `Codec` form of the
  conversation and transcript, replaced after every turn.
  """
  use Ecto.Schema

  schema "chat_sessions" do
    field :data, :map
    belongs_to :user, ResidencySchedule.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
