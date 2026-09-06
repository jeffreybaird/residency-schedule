defmodule ResidencySchedule.Repo.Migrations.CreateOauthTables do
  use Ecto.Migration

  def change do
    create table(:oauth_clients) do
      add :client_id, :string, null: false
      add :client_secret_hash, :string
      add :client_name, :string
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :token_endpoint_auth_method, :string, null: false, default: "none"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_clients, [:client_id])

    create table(:oauth_authorization_codes) do
      add :code_hash, :string, null: false
      add :client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :code_challenge_method, :string, null: false, default: "S256"
      add :scope, :string
      add :resource, :string
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])

    create table(:oauth_tokens) do
      add :access_token_hash, :string, null: false
      add :refresh_token_hash, :string
      add :client_id, references(:oauth_clients, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :scope, :string
      add :resource, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_tokens, [:access_token_hash])
    create unique_index(:oauth_tokens, [:refresh_token_hash])
    create index(:oauth_tokens, [:user_id])
  end
end
