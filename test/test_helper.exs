ResidencySchedule.MigrationDoctests.compile!("priv/repo/migrations/*_run_phase2_backfills.exs")
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ResidencySchedule.Repo, :manual)
