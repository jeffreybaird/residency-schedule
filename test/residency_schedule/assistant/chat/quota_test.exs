defmodule ResidencySchedule.Assistant.Chat.QuotaTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.Quota

  @date ~D[2026-09-07]

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        email: "quota-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    %{user: user}
  end

  describe "consume/3" do
    test "counts down from the limit and then refuses", %{user: user} do
      assert Quota.consume(user, @date, 2) == {:ok, 1}
      assert Quota.consume(user, @date, 2) == {:ok, 0}
      assert Quota.consume(user, @date, 2) == {:error, :limit_reached}
      assert Quota.remaining(user, @date, 2) == 0
    end

    test "a zero limit refuses the first message", %{user: user} do
      assert Quota.consume(user, @date, 0) == {:error, :limit_reached}
    end

    test "days are counted separately", %{user: user} do
      assert {:ok, 0} = Quota.consume(user, @date, 1)
      assert {:ok, 0} = Quota.consume(user, Date.add(@date, 1), 1)
    end

    test "uses the configured limit by default", %{user: user} do
      assert {:ok, remaining} = Quota.consume(user, @date)
      assert remaining == Chat.daily_limit() - 1
    end
  end

  describe "remaining/3" do
    test "is the full limit before any message", %{user: user} do
      assert Quota.remaining(user, @date, 5) == 5
    end

    test "never goes below zero when the limit is lowered", %{user: user} do
      {:ok, _} = Quota.consume(user, @date, 5)
      {:ok, _} = Quota.consume(user, @date, 5)
      assert Quota.remaining(user, @date, 1) == 0
    end
  end
end
