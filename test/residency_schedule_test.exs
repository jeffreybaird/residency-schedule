defmodule ResidencyScheduleTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  alias ResidencySchedule.Accounts.User

  doctest ResidencySchedule

  describe "demo_mode?/0" do
    test "returns false by default" do
      refute ResidencySchedule.demo_mode?()
    end

    test "returns true when the flag is set" do
      set_demo_mode(true)
      assert ResidencySchedule.demo_mode?()
    end

    test "returns false when the flag is explicitly disabled" do
      set_demo_mode(false)
      refute ResidencySchedule.demo_mode?()
    end
  end

  describe "demo_user/0" do
    test "is a resident, so admin checks refuse it" do
      refute User.admin?(ResidencySchedule.demo_user())
    end

    test "is approved, so the auth layer treats it as a valid session" do
      assert ResidencySchedule.demo_user().approved
    end

    test "is unpersisted, so no write path can update a real row" do
      assert ResidencySchedule.demo_user().id == nil
    end

    test "has not completed the tour, so every visitor is offered it" do
      refute ResidencySchedule.demo_user().tour_completed
    end
  end
end
