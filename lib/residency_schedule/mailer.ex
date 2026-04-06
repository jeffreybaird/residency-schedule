defmodule ResidencySchedule.Mailer do
  use Swoosh.Mailer, otp_app: :residency_schedule

  import Swoosh.Email

  @from_address "send@lennonbaird.com"

  @doc """
  Sends a magic link email to the given user.

  Exempt from doctest — sends email.
  """
  def send_magic_link(user, token, base_url) do
    url = "#{base_url}/auth/verify?token=#{token}"

    email =
      new()
      |> to(user.email)
      |> from({from_name(), @from_address})
      |> subject("Your login link — Residency Schedule")
      |> text_body("""
      Hi,

      Click the link below to sign in to Residency Schedule:

      #{url}

      This link expires in 15 minutes.

      If you didn't request this, you can safely ignore this email.
      """)
      |> html_body("""
      <p>Hi,</p>
      <p>Click the link below to sign in to Residency Schedule:</p>
      <p><a href="#{url}">Sign in to Residency Schedule</a></p>
      <p>This link expires in 15 minutes.</p>
      <p style="color: #666; font-size: 12px;">
        If you didn't request this, you can safely ignore this email.
      </p>
      """)

    case deliver(email) do
      {:ok, _metadata} = success ->
        success

      {:error, reason} = error ->
        require Logger
        Logger.error("Mailer.send_magic_link failed: #{inspect(reason)}")
        error
    end
  end

  defp from_name do
    Application.get_env(:residency_schedule, :mailer_from_name, "Residency Schedule")
  end
end
