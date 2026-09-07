defmodule ResidencyScheduleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ResidencyScheduleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ResidencyScheduleWeb.Endpoint

      use ResidencyScheduleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ResidencyScheduleWeb.ConnCase

      import ResidencySchedule.DataCase,
        only: [seed_schedule: 0, seed_schedule: 1, set_chat_enabled: 1, set_demo_mode: 1]
    end
  end

  setup tags do
    ResidencySchedule.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates an approved resident user and sets :user_id in the session so the
  `RequireAuth` plug passes. Use as `setup :authenticate_session`.
  """
  def authenticate_session(%{conn: conn}) do
    {:ok, user} =
      ResidencySchedule.Accounts.create_user(%{
        email: "test-#{System.unique_integer()}@urmc.rochester.edu"
      })

    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    %{conn: conn, user: user}
  end

  @doc """
  Creates an admin-role user and sets :user_id in the session so both the
  `RequireAuth` and `RequireAdmin` plugs pass.
  Use as `setup :admin_authenticate_session` in tests behind the admin pipeline.
  """
  def admin_authenticate_session(%{conn: conn}) do
    admin = create_admin()
    conn = Plug.Test.init_test_session(conn, user_id: admin.id)
    %{conn: conn, user: admin}
  end

  @doc """
  Creates and returns an approved admin-role user.
  """
  def create_admin(password \\ nil) do
    {:ok, user} =
      ResidencySchedule.Accounts.create_user(%{
        email: "admin-#{System.unique_integer()}@urmc.rochester.edu"
      })

    {:ok, admin} = ResidencySchedule.Accounts.set_role(user, :admin)

    if password do
      {:ok, admin_with_password} = ResidencySchedule.Accounts.set_password(admin, password)
      admin_with_password
    else
      admin
    end
  end
end
