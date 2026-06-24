defmodule Observe.QueryGraph do
  @moduledoc """
  Validates dashboard query definitions and compiles them into an execution plan.
  """

  alias Observe.Variables

  def plan(dashboard, provisioned_datasources, variable_values \\ nil) do
    variable_values =
      variable_values ||
        Variables.defaults(Map.get(dashboard, "variables", %{}), provisioned_datasources)

    vars =
      Variables.context(
        Map.get(dashboard, "variables", %{}),
        variable_values,
        provisioned_datasources
      )

    with {:ok, datasource_aliases} <-
           resolve_datasource_aliases(dashboard, provisioned_datasources, vars),
         {:ok, queries} <- executable_queries(dashboard, datasource_aliases, vars),
         {:ok, order} <- topo_sort(queries),
         :ok <- validate_panels(Map.get(dashboard, "panels", []), queries) do
      {:ok,
       %{
         variables: variable_values,
         variable_context: vars,
         datasource_aliases: datasource_aliases,
         query_order: order,
         queries: queries,
         datasets: Map.get(dashboard, "datasets", %{}),
         panels: Map.get(dashboard, "panels", [])
       }}
    end
  end

  defp executable_queries(dashboard, datasource_aliases, vars) do
    query_templates = Map.get(dashboard, "queries", %{})
    datasets = Map.get(dashboard, "datasets", %{})

    if map_size(datasets) == 0 do
      query_templates
      |> Variables.interpolate(vars)
      |> validate_queries(datasource_aliases)
    else
      with {:ok, queries} <- expand_datasets(datasets, query_templates, vars) do
        validate_queries(queries, datasource_aliases)
      end
    end
  end

  defp expand_datasets(datasets, query_templates, vars) do
    Enum.reduce_while(datasets, {:ok, %{}}, fn {dataset_name, dataset}, {:ok, acc} ->
      if not is_map(dataset) do
        {:halt, {:error, "dataset #{dataset_name} must be a map"}}
      else
        query_ref = Map.get(dataset, "query")

        cond do
          not is_binary(query_ref) or query_ref == "" ->
            {:halt, {:error, "dataset #{dataset_name} must define query"}}

          not Map.has_key?(query_templates, query_ref) ->
            {:halt,
             {:error, "dataset #{dataset_name} references unknown query #{inspect(query_ref)}"}}

          true ->
            template = Map.fetch!(query_templates, query_ref)

            with {:ok, inputs} <-
                   query_inputs(query_ref, template, Map.get(dataset, "inputs", %{}), vars) do
              query =
                template
                |> Map.drop(["inputs"])
                |> Variables.interpolate(vars, inputs)
                |> Map.put("query_ref", query_ref)
                |> Map.put("inputs", inputs)

              {:cont, {:ok, Map.put(acc, dataset_name, query)}}
            else
              {:error, reason} -> {:halt, {:error, "dataset #{dataset_name}: #{reason}"}}
            end
        end
      end
    end)
  end

  defp query_inputs(query_ref, query, provided_inputs, vars) do
    input_schema = Map.get(query, "inputs", %{})

    cond do
      not is_map(input_schema) ->
        {:error, "query #{query_ref} inputs must be a map"}

      not is_map(provided_inputs) ->
        {:error, "inputs must be a map"}

      true ->
        defaults =
          input_schema
          |> Enum.filter(fn {_name, spec} -> is_map(spec) and Map.has_key?(spec, "default") end)
          |> Map.new(fn {name, spec} -> {name, Map.get(spec, "default")} end)

        inputs =
          defaults
          |> Map.merge(provided_inputs)
          |> Variables.interpolate(vars)

        case missing_required_input(input_schema, inputs) do
          nil -> {:ok, inputs}
          name -> {:error, "query #{query_ref} missing required input #{name}"}
        end
    end
  end

  defp missing_required_input(input_schema, inputs) do
    Enum.find_value(input_schema, fn {name, spec} ->
      required? = is_map(spec) and Map.get(spec, "required") == true
      value = Map.get(inputs, name)

      if required? and (is_nil(value) or value == ""), do: name
    end)
  end

  defp resolve_datasource_aliases(dashboard, provisioned_datasources, vars) do
    dashboard
    |> Map.get("datasources", %{})
    |> Enum.reduce_while({:ok, %{}}, fn {alias_name, spec}, {:ok, acc} ->
      ref = Variables.interpolate(Map.get(spec, "ref"), vars)

      cond do
        not is_binary(ref) or ref == "" ->
          {:halt, {:error, "datasource #{alias_name} must define ref"}}

        not Map.has_key?(provisioned_datasources, ref) ->
          {:halt, {:error, "datasource #{alias_name} resolves to unknown ref #{ref}"}}

        true ->
          {:cont,
           {:ok, Map.put(acc, alias_name, %{ref: ref, config: provisioned_datasources[ref]})}}
      end
    end)
  end

  defp validate_queries(queries, datasource_aliases) do
    Enum.reduce_while(queries, {:ok, %{}}, fn {name, query}, {:ok, acc} ->
      source? = Map.has_key?(query, "datasource") or Map.has_key?(query, "request")
      derived? = Map.has_key?(query, "from") or Map.has_key?(query, "transform")

      cond do
        source? and derived? ->
          {:halt, {:error, "query #{name} cannot mix datasource/request with from/transform"}}

        source? ->
          datasource = Map.get(query, "datasource")

          if Map.has_key?(datasource_aliases, datasource) do
            {:cont, {:ok, Map.put(acc, name, Map.put(query, "kind", "source"))}}
          else
            {:halt,
             {:error, "query #{name} references unknown datasource #{inspect(datasource)}"}}
          end

        derived? ->
          from = Map.get(query, "from")

          if is_binary(from) do
            {:cont, {:ok, Map.put(acc, name, Map.put(query, "kind", "derived"))}}
          else
            {:halt, {:error, "derived query #{name} must define from"}}
          end

        true ->
          {:halt, {:error, "query #{name} must define datasource/request or from/transform"}}
      end
    end)
  end

  defp validate_panels(panels, queries) do
    missing =
      panels
      |> Enum.reject(&(Map.get(&1, "type") == "row"))
      |> Enum.flat_map(&panel_datasets/1)
      |> Enum.reject(&Map.has_key?(queries, &1))

    case missing do
      [] -> :ok
      [dataset | _] -> {:error, "panel references unknown dataset #{inspect(dataset)}"}
    end
  end

  defp panel_datasets(%{"datasets" => datasets}) when is_list(datasets), do: datasets
  defp panel_datasets(%{"dataset" => dataset}), do: [dataset]
  defp panel_datasets(_panel), do: [nil]

  defp topo_sort(queries) do
    Enum.reduce_while(Map.keys(queries), {:ok, [], MapSet.new(), MapSet.new()}, fn name,
                                                                                   {:ok, order,
                                                                                    perm, temp} ->
      case visit(name, queries, order, perm, temp) do
        {:ok, order, perm} -> {:cont, {:ok, order, perm, temp}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, order, _perm, _temp} -> {:ok, Enum.reverse(order)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp visit(name, queries, order, perm, temp) do
    cond do
      MapSet.member?(perm, name) ->
        {:ok, order, perm}

      MapSet.member?(temp, name) ->
        {:error, "query graph contains a cycle at #{name}"}

      not Map.has_key?(queries, name) ->
        {:error, "query references unknown parent #{name}"}

      true ->
        temp = MapSet.put(temp, name)
        query = queries[name]

        with {:ok, order, perm} <- visit_parent(query, queries, order, perm, temp) do
          {:ok, [name | order], MapSet.put(perm, name)}
        end
    end
  end

  defp visit_parent(%{"kind" => "derived", "from" => from}, queries, order, perm, temp) do
    visit(from, queries, order, perm, temp)
  end

  defp visit_parent(_query, _queries, order, perm, _temp), do: {:ok, order, perm}
end
