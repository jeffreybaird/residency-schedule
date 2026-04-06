defmodule ResidencySchedule.Repo.Migrations.FixHighlandRotationDates do
  use Ecto.Migration

  def up do
    # Highland Night Float runs Sunday night to Friday night.
    # Previously imported records have start_date on Monday (the weekday slot start).
    # Shift start_date back 1 day to Sunday.
    execute """
    UPDATE rotations
    SET start_date = start_date - INTERVAL '1 day'
    WHERE rotation_type = 'highland_night_float'
    """

    # Highland Weekend Nights is a single Saturday night shift.
    # Previously imported records have end_date on Sunday (the weekend slot end).
    # Set end_date equal to start_date (Saturday only).
    execute """
    UPDATE rotations
    SET end_date = start_date
    WHERE rotation_type = 'highland_weekend_nights'
    """
  end

  def down do
    # Reverse: shift Highland Night Float start_date forward 1 day (back to Monday)
    execute """
    UPDATE rotations
    SET start_date = start_date + INTERVAL '1 day'
    WHERE rotation_type = 'highland_night_float'
    """

    # Reverse: set Highland Weekend Nights end_date to start_date + 1 day (back to Sunday)
    execute """
    UPDATE rotations
    SET end_date = start_date + INTERVAL '1 day'
    WHERE rotation_type = 'highland_weekend_nights'
    """
  end
end
