defmodule ResidencySchedule.Assistant.Chat do
  @moduledoc """
  Deployment-level settings for the chat assistant, read from
  `config :residency_schedule, :chat`.
  """

  @default_daily_limit 50

  @doc """
  Whether the assistant is available on this deployment. Always false in
  demo mode, since anonymous visitors would be spending the owner's money.

      iex> ResidencySchedule.Assistant.Chat.enabled?()
      true
  """
  def enabled? do
    Keyword.get(config(), :enabled, false) and not ResidencySchedule.demo_mode?()
  end

  @doc """
  How many messages one user may send per day.

      iex> ResidencySchedule.Assistant.Chat.daily_limit()
      50
  """
  def daily_limit, do: Keyword.get(config(), :daily_message_limit, @default_daily_limit)

  defp config, do: Application.get_env(:residency_schedule, :chat, [])
end
