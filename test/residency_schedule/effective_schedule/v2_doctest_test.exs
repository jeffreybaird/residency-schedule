defmodule ResidencySchedule.EffectiveSchedule.V2DoctestTest do
  use ExUnit.Case, async: true

  doctest ResidencySchedule.EffectiveSchedule.Evidence
  doctest ResidencySchedule.EffectiveSchedule.Calendar
  doctest ResidencySchedule.EffectiveSchedule.V2
  doctest ResidencySchedule.EffectiveSchedule.Policies.NightBoundary
  doctest ResidencySchedule.EffectiveSchedule.Policies.FridayStrongCorrection
  doctest ResidencySchedule.EffectiveSchedule.Policies.CoveragePrecedence
  doctest ResidencySchedule.EffectiveSchedule.Policies.SaturdayHighlandGap
  doctest ResidencySchedule.EffectiveSchedule.Policies.GapFill
end
