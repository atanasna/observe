defmodule Observe.PanelCompatibility do
  @moduledoc """
  Runtime compatibility checks between panel types and returned dataset rows.
  """

  @known_types ~w(row table stat timeseries bargauge state-timeline)

  def validate(%{"type" => type}, _rows) when type not in @known_types do
    {:error, "Unknown panel type #{inspect(type)}"}
  end

  def validate(%{"type" => "row"}, _rows), do: :ok
  def validate(%{"type" => "table"}, _rows), do: :ok
  def validate(%{"type" => "stat"}, _rows), do: :ok
  def validate(%{"type" => "timeseries"}, []), do: :ok

  def validate(%{"type" => "timeseries"}, rows) do
    if Enum.all?(rows, &timeseries_row?/1) do
      :ok
    else
      {:error, "Timeseries panels require every row to include numeric time and value fields."}
    end
  end

  def validate(%{"type" => "state-timeline"}, []), do: :ok

  def validate(%{"type" => "state-timeline"}, rows) do
    if Enum.all?(rows, &timeseries_row?/1) and Enum.any?(rows, &has_label?/1) do
      :ok
    else
      {:error,
       "State timeline panels require numeric time/value fields and at least one label field."}
    end
  end

  def validate(%{"type" => "bargauge"}, []), do: :ok

  def validate(%{"type" => "bargauge"}, rows) do
    if Enum.all?(rows, &is_number(Map.get(&1, "value"))) do
      :ok
    else
      {:error, "Bar gauge panels require numeric value fields."}
    end
  end

  def validate(_panel, _rows), do: {:error, "Panel type is required."}

  defp timeseries_row?(row) do
    is_number(Map.get(row, "time")) and is_number(Map.get(row, "value"))
  end

  defp has_label?(row) do
    row
    |> Map.drop(["time", "value", "raw_value"])
    |> map_size()
    |> Kernel.>(0)
  end
end
