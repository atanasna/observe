defmodule Observe.Executor do
  @moduledoc """
  Executes query plans with stubbed source datasets and local transforms.
  """

  alias Observe.QueryGraph
  alias Observe.Variables
  alias Observe.Datasources.Prometheus

  def run(dashboard, params \\ %{}, opts \\ %{}) do
    datasources = Observe.Store.datasources()
    vars = Variables.merge(Map.get(dashboard, "variables", %{}), params, datasources)

    with {:ok, plan} <- QueryGraph.plan(dashboard, datasources, vars) do
      datasets =
        Enum.reduce(plan.query_order, %{}, fn name, datasets ->
          execute_query(name, plan, datasets, opts)
        end)

      {:ok, %{plan: plan, datasets: datasets}}
    end
  end

  defp execute_query(name, plan, datasets, opts) do
    query = plan.queries[name]

    dataset =
      case query["kind"] do
        "source" ->
          source_dataset(name, query, plan, opts)

        "derived" ->
          transform_dataset(Map.get(datasets, query["from"], []), Map.get(query, "transform", []))
      end

    Map.put(datasets, name, dataset)
  end

  defp source_dataset(name, query, plan, opts) do
    datasource = plan.datasource_aliases[query["datasource"]]
    type = get_in(datasource, [:config, "type"]) || get_in(datasource, ["config", "type"])
    query = Variables.interpolate(query, plan.variable_context || plan.variables)

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
