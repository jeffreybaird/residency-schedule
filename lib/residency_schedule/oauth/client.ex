defmodule ResidencySchedule.OAuth.Client do
  @moduledoc """
  An OAuth 2.1 client registered through dynamic client registration (RFC 7591).
  Public clients (`token_endpoint_auth_method: "none"`) have no secret.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @auth_methods ~w(none client_secret_post client_secret_basic)

  schema "oauth_clients" do
    field :client_id, :string
    field :client_secret_hash, :string
    field :client_name, :string
    field :redirect_uris, {:array, :string}, default: []
    field :token_endpoint_auth_method, :string, default: "none"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering a client. Every redirect URI must be an absolute
  `https` URL or an `http` URL on localhost.

      iex> cs = ResidencySchedule.OAuth.Client.changeset(
      ...>   %ResidencySchedule.OAuth.Client{},
      ...>   %{client_id: "abc", client_name: "Claude", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :client_id,
      :client_secret_hash,
      :client_name,
      :redirect_uris,
      :token_endpoint_auth_method
    ])
    |> validate_required([:client_id, :redirect_uris, :token_endpoint_auth_method])
    |> validate_inclusion(:token_endpoint_auth_method, @auth_methods)
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  @doc """
  Returns the supported token endpoint authentication methods.

      iex> ResidencySchedule.OAuth.Client.auth_methods()
      ["none", "client_secret_post", "client_secret_basic"]
  """
  def auth_methods, do: @auth_methods

  @doc """
  Returns true when the redirect URI is acceptable: absolute `https`, or `http`
  on localhost / 127.0.0.1.

      iex> ResidencySchedule.OAuth.Client.valid_redirect_uri?("https://claude.ai/api/mcp/auth_callback")
      true

      iex> ResidencySchedule.OAuth.Client.valid_redirect_uri?("http://localhost:3000/callback")
      true

      iex> ResidencySchedule.OAuth.Client.valid_redirect_uri?("http://evil.example/callback")
      false
  """
  def valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "[::1]"] -> true
      _ -> false
    end
  end

  def valid_redirect_uri?(_uri), do: false

  @doc """
  Returns true when the client must authenticate at the token endpoint.

      iex> ResidencySchedule.OAuth.Client.confidential?(%ResidencySchedule.OAuth.Client{token_endpoint_auth_method: "none"})
      false

      iex> ResidencySchedule.OAuth.Client.confidential?(%ResidencySchedule.OAuth.Client{token_endpoint_auth_method: "client_secret_post"})
      true
  """
  def confidential?(%__MODULE__{token_endpoint_auth_method: "none"}), do: false
  def confidential?(%__MODULE__{}), do: true

  # Checked via get_field rather than validate_length so an explicit empty list
  # (which equals the schema default and therefore records no change) still fails.
  defp validate_redirect_uris(changeset) do
    case get_field(changeset, :redirect_uris) do
      [] -> add_error(changeset, :redirect_uris, "must include at least one redirect URI")
      uris -> validate_redirect_uri_shapes(changeset, uris)
    end
  end

  defp validate_redirect_uri_shapes(changeset, uris) do
    if Enum.all?(uris, &valid_redirect_uri?/1) do
      changeset
    else
      add_error(changeset, :redirect_uris, "must be https URLs or http URLs on localhost")
    end
  end
end
