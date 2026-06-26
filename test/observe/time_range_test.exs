defmodule Observe.TimeRangeTest do
  use ExUnit.Case, async: true

  alias Observe.TimeRange

  test "parses supported relative time ranges" do
    range = TimeRange.range("now-15m")

    assert range.label == "now-15m"
    assert range.to > range.from
    assert (range.to - range.from) in 899..901
  end

  test "falls back to default for unknown ranges" do
    range = TimeRange.range("bogus")

    assert range.label == "bogus"
    assert (range.to - range.from) in 10_799..10_801
  end

  test "custom start and end override relative ranges" do
    range = TimeRange.custom_or_relative("2026-01-01T10:00", "2026-01-01T11:30", "now-15m")

    assert range.label == "custom"
    assert range.to - range.from == 5_400
  end

  test "parses compact durations" do
    assert TimeRange.duration_seconds("15m") == {:ok, 900}
    assert TimeRange.duration_seconds("3h") == {:ok, 10_800}
    assert TimeRange.duration_seconds("7d") == {:ok, 604_800}
    assert TimeRange.duration_seconds(60) == {:ok, 60}
    assert TimeRange.duration_seconds("later") == :error
  end

  test "custom range parses datetime-local values" do
    range = TimeRange.custom!("2026-01-01T10:00", "2026-01-01T11:30")

    assert range.label == "custom"
    assert range.to - range.from == 5_400
    assert TimeRange.valid_datetime_local?("2026-01-01T10:00")
    refute TimeRange.valid_datetime_local?("bad")
  end

  test "invalid custom range falls back to relative range" do
    range = TimeRange.custom_or_relative("bad", "2026-01-01T11:30", "now-15m")

    assert range.label == "now-15m"
    assert (range.to - range.from) in 899..901
  end
end
