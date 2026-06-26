defmodule Observe.QueryGraph do
  @moduledoc """
  Validates dashboard query definitions and compiles them into an execution plan.
  """

  alias Observe.TimeRange
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
         {:ok, queries, dataset_configs} <-
           executable_queries(dashboard, datasource_aliases, vars),
         {:ok, order} <- topo_sort(queries),
         :ok <- validate_panels(Map.get(dashboard, "panels", []), queries) do
      {:ok,
       %{
         variables: variable_values,
         variable_context: vars,
         datasource_aliases: datasource_aliases,
         query_order: order,
         queries: queries,
         processors: Map.get(dashboard, "processors", %{}),
         datasets: dataset_configs,
         panels: Map.get(dashboard, "panels", [])
       }}
    end
  end

  defp executable_queries(dashboard, datasource_aliases, vars) do
    query_templates = Map.get(dashboard, "queries", %{})
    processors = Map.get(dashboard, "processors", %{})
    datasets = Map.get(dashboard, "datasets", %{})

    if map_size(datasets) == 0 do
      with {:ok, queries} <-
             query_templates
             |> Variables.interpolate(vars)
             |> validate_queries(datasource_aliases) do
        {:ok, queries, %{}}
      end
    else
      with {:ok, queries, dataset_configs} <-
             expand_datasets(datasets, processors, query_templates, vars),
           {:ok, queries} <- validate_queries(queries, datasource_aliases) do
        {:ok, queries, dataset_configs}
      end
    end
  end

  defp expand_datasets(datasets, processors, query_templates, vars) do
    Enum.reduce_while(datasets, {:ok, %{}, %{}}, fn {dataset_name, dataset},
                                                    {:ok, queries, configs} ->
      case expand_dataset(
             dataset_name,
             dataset,
             processors,
             query_templates,
             vars,
             queries,
             configs
           ) do
        {:ok, queries, configs} -> {:cont, {:ok, queries, configs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp expand_dataset(dataset_name, dataset, processors, query_templates, vars, queries, configs) do
    cond do
      not is_map(dataset) ->
        {:error, "dataset #{dataset_name} must be a map"}

      Map.has_key?(dataset, "query") and Map.has_key?(dataset, "processor") ->
        {:error, "dataset #{dataset_name} cannot define both query and processor"}

      Map.has_key?(dataset, "query") and derived_processor?(dataset) ->
        {:error, "dataset #{dataset_name} cannot mix query with from/transform"}

      Map.has_key?(dataset, "query") and normalization_processor?(dataset) ->
        {:error, "dataset #{dataset_name} cannot define normalization without a processor"}

      Map.has_key?(dataset, "query") ->
        with {:ok, queries, configs, _node} <-
               expand_query_processor(
                 dataset_name,
                 dataset,
                 %{},
                 query_templates,
                 vars,
                 queries,
                 configs
               ) do
          config = Map.merge(Map.get(configs, dataset_name, %{}), dataset)

          {:ok, put_delay_on_sources(queries, dataset_name, dataset),
           Map.put(configs, dataset_name, config)}
        end

      processor_ref = dataset_processor_ref(dataset) ->
        provided_inputs = Map.get(dataset, "inputs", %{})

        with {:ok, queries, configs, _node} <-
               expand_processor_instance(
                 dataset_name,
                 processor_ref,
                 provided_inputs,
                 processors,
                 query_templates,
                 vars,
                 queries,
                 configs,
                 MapSet.new()
               ) do
          config = Map.merge(Map.get(configs, dataset_name, %{}), dataset)

          {:ok, put_delay_on_sources(queries, dataset_name, dataset),
           Map.put(configs, dataset_name, config)}
        end

      true ->
        with {:ok, queries, configs, node} <-
               expand_processor(
                 dataset_name,
                 dataset,
                 %{},
                 processors,
                 query_templates,
                 vars,
                 queries,
                 configs,
                 MapSet.new()
               ) do
          {:ok, put_delay_on_sources(queries, node, dataset), configs, node}
        end
    end
  end

  defp put_delay_on_sources(queries, node_name, %{"delay" => delay}) do
    put_delay_on_sources(queries, node_name, delay, MapSet.new())
  end

  defp put_delay_on_sources(queries, _node_name, _dataset), do: queries

  defp put_delay_on_sources(queries, node_name, delay, seen) do
    cond do
      MapSet.member?(seen, node_name) ->
        queries

      not Map.has_key?(queries, node_name) ->
        queries

      true ->
        seen = MapSet.put(seen, node_name)
        query = Map.fetch!(queries, node_name)

        case Map.get(query, "from") do
          parent when is_binary(parent) ->
            put_delay_on_sources(queries, parent, delay, seen)

          _parent ->
            Map.update!(queries, node_name, &Map.put(&1, "delay", delay))
        end
    end
  end

  defp dataset_processor_ref(%{"processor" => %{"name" => name}}) when is_binary(name), do: name
  defp dataset_processor_ref(%{"processor" => name}) when is_binary(name), do: name
  defp dataset_processor_ref(_dataset), do: nil

  defp expand_processor_instance(
         node_name,
         processor_ref,
         provided_inputs,
         processors,
         query_templates,
         vars,
         queries,
         configs,
         seen
       ) do
    cond do
      not Map.has_key?(processors, processor_ref) ->
        {:error, "dataset #{node_name} references unknown processor #{inspect(processor_ref)}"}

      MapSet.member?(seen, processor_ref) ->
        {:error, "processor #{processor_ref} depends on itself"}

      true ->
        processor = Map.fetch!(processors, processor_ref)

        expand_processor(
          node_name,
          processor,
          provided_inputs,
          processors,
          query_templates,
          vars,
          queries,
          Map.put(configs, node_name, processor),
          MapSet.put(seen, processor_ref)
        )
    end
  end

  defp expand_processor(
         node_name,
         processor,
         provided_inputs,
         processors,
         query_templates,
         vars,
         queries,
         configs,
         seen
       ) do
    with {:ok, inputs} <- processor_inputs(node_name, processor, provided_inputs, vars) do
      cond do
        Map.has_key?(processor, "source") ->
          expand_sourced_processor(
            node_name,
            processor,
            inputs,
            processors,
            query_templates,
            vars,
            queries,
            configs,
            seen
          )

        Map.has_key?(processor, "query") and Map.has_key?(processor, "from") ->
          {:error, "processor #{node_name} cannot mix query with from"}

        Map.has_key?(processor, "query") ->
          expand_query_processor(
            node_name,
            processor,
            inputs,
            query_templates,
            vars,
            queries,
            configs
          )

        derived_processor?(processor) ->
          expand_derived_processor(
            node_name,
            processor,
            inputs,
            processors,
            query_templates,
            vars,
            queries,
            configs,
            seen
          )

        true ->
          {:error, "processor #{node_name} must define query or from/transform"}
      end
    end
  end

  defp expand_sourced_processor(
         node_name,
         processor,
         inputs,
         processors,
         query_templates,
         vars,
         queries,
         configs,
         seen
       ) do
    case Map.get(processor, "source") do
      "query" ->
        with {:ok, query_ref, query_inputs} <- source_query(node_name, processor, vars, inputs) do
          expand_query_processor(
            node_name,
            processor
            |> Map.take(["transform"])
            |> Map.merge(%{"query" => query_ref, "inputs" => query_inputs}),
            %{},
            query_templates,
            vars,
            queries,
            configs
          )
        end

      source when source in ["processor", "dataset"] ->
        expand_processor_sourced_processor(
          node_name,
          processor,
          inputs,
          processors,
          query_templates,
          vars,
          queries,
          configs,
          seen
        )

      source ->
        {:error, "processor #{node_name} has unsupported source #{inspect(source)}"}
    end
  end

  defp expand_processor_sourced_processor(
         node_name,
         processor,
         inputs,
         processors,
         query_templates,
         vars,
         queries,
         configs,
         seen
       ) do
    with {:ok, parent_ref, parent_inputs} <- source_processor(node_name, processor, vars, inputs) do
      parent_node = parent_node_name(node_name, parent_ref)

      with {:ok, queries, configs, from} <-
             expand_processor_instance(
               parent_node,
               parent_ref,
               parent_inputs,
               processors,
               query_templates,
               vars,
               queries,
               configs,
               seen
             ) do
        query =
          processor
          |> Variables.interpolate(vars, inputs)
          |> Map.take(["transform"])
          |> Map.put("from", from)
          |> Map.put("kind", "derived")

        {:ok, Map.put(queries, node_name, query), configs, node_name}
      end
    end
  end

  defp expand_query_processor(
         node_name,
         processor,
         inputs,
         query_templates,
         vars,
         queries,
         configs
       ) do
    query_ref = query_ref(processor)
    provided_query_inputs = processor |> query_inputs_map() |> Variables.interpolate(vars, inputs)

    cond do
      not is_binary(query_ref) or query_ref == "" ->
        {:error, "processor #{node_name} must define query"}

      not Map.has_key?(query_templates, query_ref) ->
        {:error, "processor #{node_name} references unknown query #{inspect(query_ref)}"}

      true ->
        template = Map.fetch!(query_templates, query_ref)

        if derived_processor?(template) do
          {:error, "processor #{node_name} references derived query #{query_ref}"}
        else
          with {:ok, query_inputs} <-
                 query_inputs(query_ref, template, provided_query_inputs, vars) do
            query =
              template
              |> Map.drop(["inputs"])
              |> Variables.interpolate(vars, query_inputs)
              |> Map.put("query_ref", query_ref)
              |> Map.put("inputs", query_inputs)

            if Map.has_key?(processor, "transform") do
              source_node = parent_node_name(node_name, query_ref)

              derived_query =
                processor
                |> Variables.interpolate(vars, inputs)
                |> Map.take(["transform"])
                |> Map.put("from", source_node)
                |> Map.put("kind", "derived")

              queries =
                queries
                |> Map.put(source_node, query)
                |> Map.put(node_name, derived_query)

              {:ok, queries, configs, node_name}
            else
              {:ok, Map.put(queries, node_name, query), configs, node_name}
            end
          else
            {:error, reason} -> {:error, "processor #{node_name}: #{reason}"}
          end
        end
    end
  end

  defp expand_derived_processor(
         node_name,
         processor,
         inputs,
         processors,
         query_templates,
         vars,
         queries,
         configs,
         seen
       ) do
    parent_ref = processor |> Variables.interpolate(vars, inputs) |> Map.get("from")

    cond do
      not is_binary(parent_ref) or parent_ref == "" ->
        {:error, "derived processor #{node_name} must define from"}

      Map.has_key?(processors, parent_ref) ->
        parent_node = parent_node_name(node_name, parent_ref)

        with {:ok, queries, configs, from} <-
               expand_processor_instance(
                 parent_node,
                 parent_ref,
                 inputs,
                 processors,
                 query_templates,
                 vars,
                 queries,
                 configs,
                 seen
               ) do
          query =
            processor
            |> Variables.interpolate(vars, inputs)
            |> Map.take(["transform"])
            |> Map.put("from", from)
            |> Map.put("kind", "derived")

          {:ok, Map.put(queries, node_name, query), configs, node_name}
        end

      true ->
        query =
          processor
          |> Variables.interpolate(vars, inputs)
          |> Map.take(["from", "transform"])
          |> Map.put("kind", "derived")

        {:ok, Map.put(queries, node_name, query), configs, node_name}
    end
  end

  defp parent_node_name(node_name, parent_ref), do: "#{node_name}__#{parent_ref}"

  defp source_query(node_name, processor, vars, inputs) do
    query = processor |> Map.get("query", %{}) |> Variables.interpolate(vars, inputs)
    query_ref = query_ref(%{"query" => query})

    cond do
      not is_binary(query_ref) or query_ref == "" ->
        {:error, "processor #{node_name} source query must define name"}

      not is_map(Map.get(query, "inputs", %{})) ->
        {:error, "processor #{node_name} source query inputs must be a map"}

      true ->
        {:ok, query_ref, Map.get(query, "inputs", %{})}
    end
  end

  defp source_processor(node_name, processor, vars, inputs) do
    source = processor_source(processor) |> Variables.interpolate(vars, inputs)
    name = if is_map(source), do: Map.get(source, "name"), else: source

    cond do
      not is_binary(name) or name == "" ->
        {:error, "processor #{node_name} source processor must define name"}

      is_map(source) and not is_map(Map.get(source, "inputs", %{})) ->
        {:error, "processor #{node_name} source processor inputs must be a map"}

      true ->
        {:ok, name, if(is_map(source), do: Map.get(source, "inputs", %{}), else: inputs)}
    end
  end

  defp processor_source(%{"processor" => source}), do: source
  defp processor_source(%{"dataset" => source}), do: source

  defp query_ref(%{"query" => %{"name" => name}}), do: name
  defp query_ref(%{"query" => name}) when is_binary(name), do: name
  defp query_ref(_processor), do: nil

  defp query_inputs_map(%{"query" => %{"inputs" => inputs}}) when is_map(inputs), do: inputs
  defp query_inputs_map(%{"inputs" => inputs}) when is_map(inputs), do: inputs
  defp query_inputs_map(_processor), do: %{}

  defp processor_inputs(node_name, processor, provided_inputs, vars) do
    input_schema = Map.get(processor, "inputs", %{})

    input_values("processor", node_name, input_schema, provided_inputs, vars)
  end

  defp derived_processor?(query) do
    Map.has_key?(query, "from") or Map.has_key?(query, "transform")
  end

  defp normalization_processor?(query) do
    Map.has_key?(query, "no_value") or Map.has_key?(query, "fill_missing")
  end

  defp query_inputs(query_ref, query, provided_inputs, vars) do
    input_values("query", query_ref, Map.get(query, "inputs", %{}), provided_inputs, vars)
  end

  defp input_values(type, name, input_schema, provided_inputs, vars) do
    cond do
      not is_map(input_schema) ->
        {:error, "#{type} #{name} inputs must be a map"}

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

        cond do
          input_name = unknown_input(input_schema, provided_inputs) ->
            {:error, "#{type} #{name} received unknown input #{input_name}"}

          input_name = missing_required_input(input_schema, inputs) ->
            {:error, "#{type} #{name} missing required input #{input_name}"}

          true ->
            {:ok, inputs}
        end
    end
  end

  defp unknown_input(input_schema, inputs) do
    Enum.find_value(inputs, fn {name, _value} ->
      if Map.has_key?(input_schema, name), do: nil, else: name
    end)
  end

  defp missing_required_input(input_schema, inputs) do
    Enum.find_value(input_schema, fn {name, spec} ->
      required? = not (is_map(spec) and Map.get(spec, "required") == false)
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

          cond do
            not Map.has_key?(datasource_aliases, datasource) ->
              {:halt,
               {:error, "query #{name} references unknown datasource #{inspect(datasource)}"}}

            invalid_delay?(query) ->
              {:halt,
               {:error, "query #{name} has invalid delay #{inspect(Map.get(query, "delay"))}"}}

            true ->
              {:cont, {:ok, Map.put(acc, name, Map.put(query, "kind", "source"))}}
          end

        derived? ->
          from = Map.get(query, "from")

          if is_binary(from) do
            {:cont, {:ok, Map.put(acc, name, Map.put(query, "kind", "derived"))}}
          else
            {:halt, {:error, "derived processor #{name} must define from"}}
          end

        true ->
          {:halt, {:error, "query #{name} must define datasource/request or from/transform"}}
      end
    end)
  end

  defp invalid_delay?(%{"delay" => delay}), do: TimeRange.duration_seconds(delay) == :error
  defp invalid_delay?(_query), do: false

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

  defp panel_datasets(%{"datasets" => datasets}) when is_list(datasets) do
    Enum.map(datasets, fn
      dataset when is_binary(dataset) -> dataset
      %{"name" => dataset} when is_binary(dataset) -> dataset
      _dataset -> nil
    end)
  end

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
