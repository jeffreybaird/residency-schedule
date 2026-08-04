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

  @doc """
  Sends an approval notification email to a user.

  Exempt from doctest — sends email.
  """
  def send_approval_email(user, base_url) do
    email =
      new()
      |> to(user.email)
      |> from({from_name(), @from_address})
      |> subject("You've been approved — Residency Schedule")
      |> text_body("""
      Hi,

      Your account has been approved! You can now sign in to Residency Schedule:

      #{base_url}/login

      If you have any questions, just reply to this email.
      """)
      |> html_body("""
      <p>Hi,</p>
      <p>Your account has been approved! You can now sign in to Residency Schedule:</p>
      <p><a href="#{base_url}/login">Sign in to Residency Schedule</a></p>
      <p style="color: #666; font-size: 12px;">
        If you have any questions, just reply to this email.
      </p>
      """)

    case deliver(email) do
      {:ok, _metadata} = success ->
        success

      {:error, reason} = error ->
        require Logger
        Logger.error("Mailer.send_approval_email failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Sends a denial notification email to a user whose approval was declined.

  Exempt from doctest — sends email.
  """
  def send_denial_email(user, base_url) do
    email =
      new()
      |> to(user.email)
      |> from({from_name(), @from_address})
      |> subject("Update on your access request — Residency Schedule")
      |> text_body("""
      Hi,

      Thanks for your interest in Residency Schedule. After review, your
      access request was not approved at this time.

      If you believe this was a mistake, just reply to this email and an
      administrator can take another look:

      #{base_url}/login
      """)
      |> html_body("""
      <p>Hi,</p>
      <p>Thanks for your interest in Residency Schedule. After review, your
      access request was not approved at this time.</p>
      <p>If you believe this was a mistake, just reply to this email and an
      administrator can take another look.</p>
      <p style="color: #666; font-size: 12px;">
        <a href="#{base_url}/login">Residency Schedule</a>
      </p>
      """)

    case deliver(email) do
      {:ok, _metadata} = success ->
        success

      {:error, reason} = error ->
        require Logger
        Logger.error("Mailer.send_denial_email failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Notifies the admin that a new user is requesting approval.

  Exempt from doctest — sends email.
  """
  def send_approval_request_email(user, base_url) do
    email =
      new()
      |> to(admin_email())
      |> from({from_name(), @from_address})
      |> subject("New approval request — #{user.email}")
      |> text_body("""
      A new user has signed up and is waiting for approval:

      Email: #{user.email}
      Signed up: #{Calendar.strftime(user.inserted_at, "%b %-d, %Y at %-I:%M %p UTC")}

      Review pending users at: #{base_url}/admin
      """)
      |> html_body("""
      <p>A new user has signed up and is waiting for approval:</p>
      <p><strong>Email:</strong> #{user.email}</p>
      <p><strong>Signed up:</strong> #{Calendar.strftime(user.inserted_at, "%b %-d, %Y at %-I:%M %p UTC")}</p>
      <p><a href="#{base_url}/admin">Review pending users</a></p>
      """)

    case deliver(email) do
      {:ok, _metadata} = success ->
        success

      {:error, reason} = error ->
        require Logger
        Logger.error("Mailer.send_approval_request_email failed: #{inspect(reason)}")
        error
    end
  end

  defp admin_email, do: "jeffreybaird@hey.com"

  defp from_name do
    Application.get_env(:residency_schedule, :mailer_from_name, "Residency Schedule")
  end
end
