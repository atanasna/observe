defmodule Observe.Executor do
  @moduledoc """
  Executes query plans with stubbed source datasets and local transforms.
  """

  alias Observe.QueryGraph
  alias Observe.Variables
  alias Observe.Datasources.Prometheus

  def run(dashboard, params \\ %{}, opts \\ %{}) do
    datasources = datasources(opts)
    vars = Variables.merge(Map.get(dashboard, "variables", %{}), params, datasources)

    with {:ok, plan} <- QueryGraph.plan(dashboard, datasources, vars) do
      datasets = execute_plan(plan, opts, fn _event -> :ok end)

      {:ok, %{plan: plan, datasets: datasets}}
    end
  end

  def run_stream(dashboard, params, opts, notify) when is_function(notify, 1) do
    datasources = datasources(opts)
    vars = Variables.merge(Map.get(dashboard, "variables", %{}), params, datasources)

    with {:ok, plan} <- QueryGraph.plan(dashboard, datasources, vars) do
      notify.({:plan, plan})

      execute_plan(plan, opts, notify)

      notify.(:complete)
      :ok
    end
  end

  defp datasources(opts), do: Map.get(opts, :datasources) || Observe.Store.datasources()

  defp execute_plan(plan, opts, notify) do
    execute_pending(plan.query_order, plan, %{}, opts, notify)
  end

  defp execute_pending([], _plan, datasets, _opts, _notify), do: datasets

  defp execute_pending(pending, plan, datasets, opts, notify) do
    {runnable, waiting} = Enum.split_with(pending, &runnable?(&1, plan, datasets))

    if runnable == [] do
      datasets
    else
      datasets = execute_runnable(runnable, plan, datasets, opts, notify)
      execute_pending(waiting, plan, datasets, opts, notify)
    end
  end

  defp runnable?(name, plan, datasets) do
    query = plan.queries[name]

    query["kind"] == "source" or Map.has_key?(datasets, query["from"])
  end

  defp execute_runnable(runnable, plan, datasets, opts, notify) do
    runnable
    |> Task.async_stream(
      fn name ->
        {name, query_dataset(name, plan, datasets, opts) |> normalize_dataset(name, plan, opts)}
      end,
      max_concurrency: max_concurrency(opts),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(datasets, fn {:ok, {name, dataset}}, acc ->
      notify.({:dataset, name, dataset})
      Map.put(acc, name, dataset)
    end)
  end

  defp max_concurrency(opts) do
    case Map.get(opts, :max_concurrency) do
      value when is_integer(value) and value > 0 -> value
      _value -> System.schedulers_online()
    end
  end

  defp query_dataset(name, plan, datasets, opts) do
    query = plan.queries[name]

    case query["kind"] do
      "source" ->
        source_dataset(name, query, plan, opts)

      "derived" ->
        transform_dataset(Map.get(datasets, query["from"], []), Map.get(query, "transform", []))
    end
  end

  defp normalize_dataset(rows, name, plan, opts) do
    dataset = Map.get(plan.datasets || %{}, name, %{})
    query = Map.get(plan.queries || %{}, name, %{})

    rows
    |> normalize_no_value(dataset)
    |> fill_missing_rows(dataset, query, opts)
  end

  defp normalize_no_value(rows, dataset) do
    case Map.get(dataset, "no_value") do
      replacement when is_number(replacement) ->
        Enum.map(rows, &replace_no_value(&1, replacement))

      _value ->
        rows
    end
  end

  defp replace_no_value(%{} = row, replacement) do
    if no_value?(Map.get(row, "value")) do
      Map.put(row, "value", replacement)
    else
      row
    end
  end

  defp replace_no_value(row, _replacement), do: row

  defp no_value?(value), do: value in [nil, "NaN", "Inf", "+Inf", "-Inf"]

  defp fill_missing_rows(rows, dataset, query, opts) do
    with fill_value when is_number(fill_value) <- Map.get(dataset, "fill_missing"),
         %{from: from, to: to} <- Map.get(opts, :time_range),
         step when is_integer(step) and step > 0 <- query_step_seconds(query),
         [_ | _] = timestamps <- expected_timestamps(from, to, step) do
      fill_series(rows, timestamps, fill_value)
    else
      _value -> rows
    end
  end

  defp query_step_seconds(query) do
    query
    |> get_in(["request", "step"])
    |> Kernel.||(get_in(query, ["request", "interval"]))
    |> interval_seconds()
  end

  defp interval_seconds(value) when is_integer(value) and value > 0, do: value

  defp interval_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {amount, "s"} when amount > 0 -> amount
      {amount, "m"} when amount > 0 -> amount * 60
      {amount, "h"} when amount > 0 -> amount * 60 * 60
      {amount, ""} when amount > 0 -> amount
      _invalid -> nil
    end
  end

  defp interval_seconds(_value), do: nil

  defp expected_timestamps(from, to, step)
       when is_integer(from) and is_integer(to) and from <= to do
    Enum.to_list(from..to//step)
  end

  defp expected_timestamps(_from, _to, _step), do: []

  defp fill_series(rows, timestamps, fill_value) do
    rows
    |> Enum.group_by(&series_key/1)
    |> Enum.flat_map(fn {labels, series_rows} ->
      rows_by_time = Map.new(series_rows, &{Map.get(&1, "time"), &1})

      Enum.map(timestamps, fn timestamp ->
        Map.get(rows_by_time, timestamp) ||
          Map.merge(labels, %{"time" => timestamp, "value" => fill_value})
      end)
    end)
  end

  defp series_key(row) do
    row
    |> Map.drop(["time", "value", "raw_value", "dataset", "legend_format"])
  end

  defp source_dataset(name, query, plan, opts) do
    datasource = plan.datasource_aliases[query["datasource"]]
    type = get_in(datasource, [:config, "type"]) || get_in(datasource, ["config", "type"])
    query = Variables.interpolate(query, plan.variable_context || plan.variables)

    case Map.get(opts, :source_dataset) do
      fun when is_function(fun, 2) ->
        fun.(name, query)

      _fun ->
        case type do
          "prometheus" ->
            prometheus_rows(name, datasource[:config] || datasource["config"], query, opts)

          "cloudwatch" ->
            cloudwatch_rows(name)

          "opensearch" ->
            opensearch_rows(name)

          _ ->
            generic_rows(name)
        end
    end
  end

  defp transform_dataset(rows, transforms) do
    Enum.reduce(transforms || [], rows, fn transform, acc ->
      cond do
        filter = transform["filter"] -> filter_rows(acc, filter)
        select = transform["select"] -> select_rows(acc, select)
        sort = transform["sort"] -> sort_rows(acc, sort)
        limit = transform["limit"] -> Enum.take(acc, limit)
        true -> acc
      end
    end)
  end

  defp filter_rows(rows, filter) do
    field = filter["field"]

    Enum.filter(rows, fn row ->
      value = Map.get(row, field)

      Enum.all?(filter, fn
        {"field", _} -> true
        {"eq", expected} -> value == expected
        {"gt", expected} -> comparable?(value, expected) and value > expected
        {"gte", expected} -> comparable?(value, expected) and value >= expected
        {"lt", expected} -> comparable?(value, expected) and value < expected
        {"lte", expected} -> comparable?(value, expected) and value <= expected
        _ -> true
      end)
    end)
  end

  defp comparable?(left, right), do: is_number(left) and is_number(right)

  defp select_rows(rows, %{"fields" => fields}) when is_list(fields) do
    Enum.map(rows, &Map.take(&1, fields))
  end

  defp select_rows(rows, _select), do: rows

  defp sort_rows(rows, %{"field" => field} = sort) do
    direction = Map.get(sort, "direction", "asc")
    Enum.sort_by(rows, &Map.get(&1, field), if(direction == "desc", do: :desc, else: :asc))
  end

  defp sort_rows(rows, _sort), do: rows

  defp prometheus_rows(name, %{"mode" => "real"} = datasource, query, opts) do
    request = apply_time_range(Map.get(query, "request", %{}), opts)

    case Prometheus.execute(datasource, request) do
      {:ok, rows} -> rows
      {:error, reason} -> [%{"query" => name, "error" => reason, "value" => nil}]
    end
  end

  defp prometheus_rows(_name, _datasource, _query, _opts) do
    [
      %{"time" => "10:00", "service" => "api", "value" => 184},
      %{"time" => "10:01", "service" => "api", "value" => 211},
      %{"time" => "10:02", "service" => "worker", "value" => 89}
    ]
  end

  defp apply_time_range(%{"range" => true} = request, %{time_range: %{from: from, to: to}}) do
    request
    |> Map.put_new("start", from)
    |> Map.put_new("end", to)
  end

  defp apply_time_range(request, _opts), do: request

  defp cloudwatch_rows(_name) do
    [
      %{"instance" => "i-eu-001", "metric" => "CPUUtilization", "value" => 91.2},
      %{"instance" => "i-eu-002", "metric" => "CPUUtilization", "value" => 37.4},
      %{"instance" => "i-eu-003", "metric" => "CPUUtilization", "value" => 76.1}
    ]
  end

  defp opensearch_rows(_name) do
    [
      %{
        "timestamp" => "2026-06-19T10:00:00Z",
        "service" => "api",
        "status" => 500,
        "level" => "error",
        "message" => "checkout failed"
      },
      %{
        "timestamp" => "2026-06-19T10:01:00Z",
        "service" => "api",
        "status" => 200,
        "level" => "info",
        "message" => "request complete"
      },
      %{
        "timestamp" => "2026-06-19T10:02:00Z",
        "service" => "worker",
        "status" => 503,
        "level" => "error",
        "message" => "queue timeout"
      }
    ]
  end

  defp generic_rows(name), do: [%{"query" => name, "value" => 1}]
end
