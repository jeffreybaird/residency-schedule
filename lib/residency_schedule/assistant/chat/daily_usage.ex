defmodule ResidencySchedule.Assistant.Chat.DailyUsage do
  @moduledoc """
  How many chat messages one user has sent on one day.
  """
  use Ecto.Schema

  schema "chat_daily_usage" do
    field :date, :date
    field :messages, :integer, default: 0
    belongs_to :user, ResidencySchedule.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
