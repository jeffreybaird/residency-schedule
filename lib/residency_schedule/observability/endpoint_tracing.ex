defmodule ResidencySchedule.Observability.EndpointTracing do
  @moduledoc false

  # Registered after Phoenix.Endpoint so cleanup surrounds its error renderer too.
  @doc false
  defmacro __before_compile__(_) do
    quote do
      alias ResidencySchedule.Observability.Tracing

      defoverridable call: 2

      def call(conn, opts) do
        Tracing.request(conn, fn -> super(conn, opts) end)
      end
    end
  end
end
