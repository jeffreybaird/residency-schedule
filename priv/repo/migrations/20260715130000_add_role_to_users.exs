defmodule ResidencySchedule.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  @operator_emails "'brendablennon@gmail.com', 'clarelennonbaird@gmail.com', 'jlbaird87@gmail.com'"

  def change do
    alter table(:users) do
      add :role, :string, null: false, default: "user"
    end

    create constraint(:users, :role_must_be_valid, check: "role IN ('user', 'resident', 'admin')")

    # Backfill existing accounts: the three operator addresses (previously a
    # hardcoded auto-approve whitelist) become admins, URMC emails become
    # residents, and everything else keeps the default user role.
    execute(
      """
      UPDATE users SET role = CASE
        WHEN email IN (#{@operator_emails}) THEN 'admin'
        WHEN email LIKE '%@urmc.rochester.edu' THEN 'resident'
        ELSE 'user'
      END
      """,
      "UPDATE users SET role = 'user'"
    )
  end
end
