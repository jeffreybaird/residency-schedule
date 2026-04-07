defmodule ResidencySchedule.MailerTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias ResidencySchedule.Mailer

  describe "send_approval_email/2" do
    test "sends an approval notification to the user" do
      user = %{email: "resident@urmc.rochester.edu"}
      base_url = "https://example.com"

      assert {:ok, _} = Mailer.send_approval_email(user, base_url)

      assert_email_sent(
        to: [{nil, "resident@urmc.rochester.edu"}],
        subject: "You've been approved — Residency Schedule"
      )
    end

    test "includes a login link in the email body" do
      user = %{email: "test@gmail.com"}
      base_url = "https://schedule.example.com"

      {:ok, _} = Mailer.send_approval_email(user, base_url)

      assert_email_sent(fn email ->
        assert email.text_body =~ "https://schedule.example.com/login"
        assert email.html_body =~ "https://schedule.example.com/login"
      end)
    end
  end

  describe "send_approval_request_email/2" do
    test "sends a notification to the admin" do
      user = %{email: "newuser@gmail.com", inserted_at: ~U[2026-04-07 14:30:00Z]}
      base_url = "https://example.com"

      assert {:ok, _} = Mailer.send_approval_request_email(user, base_url)

      assert_email_sent(
        to: [{nil, "jeffreybaird@hey.com"}],
        subject: "New approval request — newuser@gmail.com"
      )
    end

    test "includes user email and admin link in the body" do
      user = %{email: "pending@gmail.com", inserted_at: ~U[2026-04-07 14:30:00Z]}
      base_url = "https://schedule.example.com"

      {:ok, _} = Mailer.send_approval_request_email(user, base_url)

      assert_email_sent(fn email ->
        assert email.text_body =~ "pending@gmail.com"
        assert email.text_body =~ "https://schedule.example.com/admin"
        assert email.html_body =~ "pending@gmail.com"
        assert email.html_body =~ "https://schedule.example.com/admin"
      end)
    end
  end
end
