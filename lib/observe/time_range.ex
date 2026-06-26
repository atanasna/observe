defmodule Observe.TimeRange do
  @moduledoc """
  Parses compact dashboard time ranges like `now-3h`.
  """

  @ranges %{
    "now-15m" => -15 * 60,
    "now-30m" => -30 * 60,
    "now-1h" => -60 * 60,
    "now-3h" => -3 * 60 * 60,
    "now-6h" => -6 * 60 * 60,
    "now-12h" => -12 * 60 * 60,
    "now-24h" => -24 * 60 * 60,
    "now-7d" => -7 * 24 * 60 * 60
  }

  def options do
    [
      {"Last 15m", "now-15m"},
      {"Last 30m", "now-30m"},
      {"Last 1h", "now-1h"},
      {"Last 3h", "now-3h"},
      {"Last 6h", "now-6h"},
      {"Last 12h", "now-12h"},
      {"Last 24h", "now-24h"},
      {"Last 7d", "now-7d"}
    ]
  end

  def default, do: "now-3h"

  def duration_seconds(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def duration_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {amount, "s"} when amount >= 0 -> {:ok, amount}
      {amount, "m"} when amount >= 0 -> {:ok, amount * 60}
      {amount, "h"} when amount >= 0 -> {:ok, amount * 60 * 60}
      {amount, "d"} when amount >= 0 -> {:ok, amount * 24 * 60 * 60}
      {amount, ""} when amount >= 0 -> {:ok, amount}
      _invalid -> :error
    end
  end

  def duration_seconds(_value), do: :error

  def range(value \\ default()) do
    seconds = Map.get(@ranges, value, @ranges[default()])
    now = DateTime.utc_now()

    %{
      from: now |> DateTime.add(seconds, :second) |> DateTime.to_unix(),
      to: DateTime.to_unix(now),
      label: value
    }
  end

  def custom_or_relative(start_value, end_value, relative_value \\ default()) do
    with {:ok, from} <- parse_datetime_local(start_value),
         {:ok, to} <- parse_datetime_local(end_value),
         true <- from < to do
      %{from: from, to: to, label: "custom"}
    else
      _ -> range(relative_value)
    end
  end

  def custom!(start_value, end_value) do
    with {:ok, from} <- parse_datetime_local(start_value),
         {:ok, to} <- parse_datetime_local(end_value),
         true <- from < to do
      %{from: from, to: to, label: "custom"}
    else
      _ -> raise ArgumentError, "invalid custom time range"
    end
  end

  def valid_datetime_local?(value), do: match?({:ok, _unix}, parse_datetime_local(value))

  def datetime_local(%{from: from, to: to}) do
    %{start: format_datetime_local(from), end: format_datetime_local(to)}
  end

  defp parse_datetime_local(value) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}
      {:error, _reason} -> :error
    end
  end

  defp parse_datetime_local(_value), do: :error

  defp format_datetime_local(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end
end
