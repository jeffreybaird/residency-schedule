defmodule ResidencySchedule do
  @moduledoc """
  ResidencySchedule keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias ResidencySchedule.Accounts.User

  @doc """
  Reports whether the application is running as a public demo.

  Demo deployments serve synthetic data with no login, so they must refuse
  every write the UI would otherwise allow.

      iex> ResidencySchedule.demo_mode?()
      false
  """
  def demo_mode? do
    Application.get_env(:residency_schedule, :demo_mode, false)
  end

  @doc """
  Returns the stand-in user assigned to anonymous demo visitors.

  The auth layer assigns `:current_user` on every request and the templates
  dereference it, so demo mode needs a user rather than a plain bypass. This
  one is never persisted and carries the `:resident` role, so every admin
  check and every write path refuses it exactly as it would a real resident.

      iex> ResidencySchedule.demo_user().role
      :resident

      iex> ResidencySchedule.demo_user().id
      nil
  """
  def demo_user do
    %User{
      id: nil,
      email: "demo@example.invalid",
      role: :resident,
      approved: true,
      tour_completed: true
    }
  end
end
