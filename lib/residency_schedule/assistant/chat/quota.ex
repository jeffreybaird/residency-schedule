defmodule ResidencySchedule.Assistant.Chat.Quota do
  @moduledoc """
  A per-user daily message cap, counted in the database so it survives
  restarts and holds across nodes.
  """

  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.DailyUsage
  alias ResidencySchedule.Repo

  @doc """
  Messages the user may still send on `date`.

  Exempt from doctest — hits the database. See `QuotaTest`.
  """
  def remaining(%User{id: user_id}, %Date{} = date, limit \\ Chat.daily_limit()) do
    max(limit - used(user_id, date), 0)
  end

  @doc """
  Counts one message against the user's day. Returns `{:ok, remaining}` or
  `{:error, :limit_reached}` without counting.

  Exempt from doctest — hits the database. See `QuotaTest`.
  """
  def consume(%User{id: user_id}, %Date{} = date, limit \\ Chat.daily_limit()) do
    case increment_below(user_id, date, limit) do
      {1, [messages]} -> {:ok, limit - messages}
      {0, _} -> insert_first(user_id, date, limit)
    end
  end

  defp used(user_id, date) do
    DailyUsage
    |> where([u], u.user_id == ^user_id and u.date == ^date)
    |> select([u], u.messages)
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp increment_below(user_id, date, limit) do
    DailyUsage
    |> where([u], u.user_id == ^user_id and u.date == ^date and u.messages < ^limit)
    |> select([u], u.messages)
    |> Repo.update_all(inc: [messages: 1])
  end

  defp insert_first(_user_id, _date, limit) when limit < 1, do: {:error, :limit_reached}

  defp insert_first(user_id, date, limit) do
    %DailyUsage{user_id: user_id, date: date, messages: 1}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :date])
    |> first_result(limit)
  end

  defp first_result({:ok, %DailyUsage{id: nil}}, _limit), do: {:error, :limit_reached}
  defp first_result({:ok, %DailyUsage{}}, limit), do: {:ok, limit - 1}
end
