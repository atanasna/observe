defmodule Observe.PanelCompatibilityTest do
  use ExUnit.Case, async: true

  alias Observe.PanelCompatibility

  test "timeseries panels require numeric time and value fields" do
    assert :ok =
             PanelCompatibility.validate(%{"type" => "timeseries"}, [
               %{"time" => 1, "value" => 2.0, "service" => "api"}
             ])

    assert {:error, _reason} =
             PanelCompatibility.validate(%{"type" => "timeseries"}, [%{"value" => 2.0}])
  end

  test "table and row panels are broadly compatible" do
    assert :ok = PanelCompatibility.validate(%{"type" => "table"}, [%{"anything" => true}])
    assert :ok = PanelCompatibility.validate(%{"type" => "row"}, [])
  end

  test "bargauge panels require numeric values" do
    assert :ok = PanelCompatibility.validate(%{"type" => "bargauge"}, [%{"value" => 10}])

    assert {:error, _reason} =
             PanelCompatibility.validate(%{"type" => "bargauge"}, [%{"value" => "bad"}])
  end
end
