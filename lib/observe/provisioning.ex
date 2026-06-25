defmodule Observe.Provisioning do
  @moduledoc """
  Loads YAML-provisioned datasources, queries, datasets, and dashboards.
  """

  alias Observe.QueryGraph
  alias Observe.Variables

  @datasource_dir Path.expand("../../config/datasources", __DIR__)
  @query_dir Path.expand("../../config/queries", __DIR__)
  @dataset_dir Path.expand("../../config/datasets", __DIR__)
  @dashboard_dir Path.expand("../../config/dashboards", __DIR__)

  def load do
    with {:ok, datasources} <- load_datasources(),
         {:ok, queries} <- load_queries(),
         {:ok, datasets} <- load_datasets(),
         {:ok, dashboards} <- load_dashboards(datasources, queries, datasets) do
      {:ok,
       %{datasources: datasources, queries: queries, datasets: datasets, dashboards: dashboards}}
    end
  end

  def load_datasources(dir \\ @datasource_dir) do
    dir
    |> yaml_files()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_yaml(path) do
        {:ok, %{"datasources" => datasources} = document} when is_map(datasources) ->
          document_folder = get_in(document, ["metadata", "folder"])

          datasources =
            Map.new(datasources, fn {name, config} ->
              config = Variables.interpolate(config, %{})
              {name, put_metadata(config, dir, path, document_folder)}
            end)

          {:cont, {:ok, Map.merge(acc, datasources)}}

        {:ok, _} ->
          {:halt, {:error, "#{path} must contain a datasources map"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def load_queries(dir \\ @query_dir) do
    dir
    |> yaml_files()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_yaml(path) do
        {:ok, %{"queries" => queries} = document} when is_map(queries) ->
          document_folder = get_in(document, ["metadata", "folder"])

          queries =
            Map.new(queries, fn {name, query} ->
              {name, put_metadata(query, dir, path, document_folder)}
            end)

          {:cont, {:ok, Map.merge(acc, queries)}}

        {:ok, _} ->
          {:halt, {:error, "#{path} must contain a queries map"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def load_datasets(dir \\ @dataset_dir) do
    dir
    |> yaml_files()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_yaml(path) do
        {:ok, %{"datasets" => datasets} = document} when is_map(datasets) ->
          document_folder = get_in(document, ["metadata", "folder"])

          datasets =
            Map.new(datasets, fn {name, dataset} ->
              {name, put_metadata(dataset, dir, path, document_folder)}
            end)

          {:cont, {:ok, Map.merge(acc, datasets)}}

        {:ok, _} ->
          {:halt, {:error, "#{path} must contain a datasets map"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def load_dashboards(datasources, queries \\ %{}, datasets \\ %{}, dir \\ @dashboard_dir) do
    dir
    |> yaml_files()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_yaml(path) do
        {:ok, dashboard} ->
          with {:ok, normalized} <- normalize_dashboard(dashboard, path),
               {:ok, resolved} <- resolve_dashboard_datasets(normalized, datasets),
               {:ok, resolved} <- resolve_dashboard_queries(resolved, queries),
               {:ok, plan} <- QueryGraph.plan(resolved, datasources) do
            name = get_in(resolved, ["metadata", "name"])

            dashboard =
              resolved
              |> put_metadata(dir, path, get_in(resolved, ["metadata", "folder"]))
              |> Map.put("plan", plan)

            {:cont, {:ok, Map.put(acc, name, dashboard)}}
          else
            {:error, _reason} -> {:cont, {:ok, acc}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_dashboard(%{"kind" => "Dashboard"} = dashboard, path) do
    name = get_in(dashboard, ["metadata", "name"])

    cond do
      not is_binary(name) or name == "" ->
        {:error, "dashboard metadata.name is required"}

      not is_map(Map.get(dashboard, "queries", %{})) ->
        {:error, "dashboard queries must be a map"}

      not is_list(Map.get(dashboard, "queryRefs", [])) ->
        {:error, "dashboard queryRefs must be a list"}

      not is_map(Map.get(dashboard, "datasetRefs", %{})) ->
        {:error, "dashboard datasetRefs must be a map"}

      not is_map(Map.get(dashboard, "datasets", %{})) ->
        {:error, "dashboard datasets must be a map"}

      not is_list(Map.get(dashboard, "panels", [])) ->
        {:error, "dashboard panels must be a list"}

      true ->
        {:ok,
         dashboard
         |> put_variable_order(path)
         |> Map.put_new("variables", %{})
         |> Map.put_new("datasources", %{})
         |> Map.put_new("queryRefs", [])
         |> Map.put_new("datasetRefs", %{})
         |> Map.put_new("queries", %{})
         |> Map.put_new("datasets", %{})
         |> Map.put_new("panels", [])}
    end
  end

  defp normalize_dashboard(_dashboard, _path), do: {:error, "kind must be Dashboard"}

  defp resolve_dashboard_queries(dashboard, provisioned_queries) do
    query_refs =
      dashboard
      |> Map.get("queryRefs", [])
      |> Enum.concat(inferred_query_refs(Map.get(dashboard, "datasets", %{})))
      |> Enum.uniq()

    with {:ok, referenced_queries} <-
           referenced_queries(query_refs, provisioned_queries) do
      {:ok,
       Map.put(
         dashboard,
         "queries",
         Map.merge(referenced_queries, Map.get(dashboard, "queries", %{}))
       )}
    end
  end

  defp inferred_query_refs(datasets) do
    datasets
    |> Enum.flat_map(fn {name, dataset} ->
      inferred_query_refs(name, dataset, datasets, MapSet.new())
    end)
  end

  defp inferred_query_refs(name, dataset, datasets, seen) do
    if MapSet.member?(seen, name) do
      []
    else
      seen = MapSet.put(seen, name)

      cond do
        Map.get(dataset, "source") == "query" ->
          case get_in(dataset, ["query", "name"]) do
            query_name when is_binary(query_name) and query_name != "" -> [query_name]
            _query_name -> []
          end

        Map.get(dataset, "source") == "dataset" ->
          parent_name = get_in(dataset, ["dataset", "name"])

          case Map.get(datasets, parent_name) do
            %{} = parent -> inferred_query_refs(parent_name, parent, datasets, seen)
            _parent -> []
          end

        is_binary(Map.get(dataset, "query")) ->
          [Map.get(dataset, "query")]

        true ->
          []
      end
    end
  end

  defp referenced_queries(query_refs, provisioned_queries) do
    Enum.reduce_while(query_refs, {:ok, %{}}, fn name, {:ok, acc} ->
      case Map.fetch(provisioned_queries, name) do
        {:ok, query} ->
          {:cont, {:ok, Map.put(acc, name, Map.drop(query, ["_meta"]))}}

        :error ->
          {:halt, {:error, "dashboard references unknown query #{inspect(name)}"}}
      end
    end)
  end

  defp resolve_dashboard_datasets(dashboard, provisioned_datasets) do
    with {:ok, referenced_datasets} <-
           referenced_datasets(Map.get(dashboard, "datasetRefs", %{}), provisioned_datasets) do
      {:ok,
       Map.put(
         dashboard,
         "datasets",
         Map.merge(referenced_datasets, Map.get(dashboard, "datasets", %{}))
       )}
    end
  end

  defp referenced_datasets(dataset_refs, provisioned_datasets) do
    Enum.reduce_while(dataset_refs, {:ok, %{}}, fn {name, ref}, {:ok, acc} ->
      with {:ok, dataset_name, inputs} <- dataset_ref(name, ref),
           {:ok, dataset} <- fetch_dataset(dataset_name, provisioned_datasets) do
        dataset =
          dataset
          |> Map.drop(["_meta"])
          |> Map.put("_dataset_ref", dataset_name)
          |> Map.put("_input_schema", Map.get(dataset, "inputs", %{}))
          |> Map.put("inputs", inputs)

        {:cont, {:ok, Map.put(acc, name, dataset)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp dataset_ref(_name, %{"dataset" => dataset_name} = ref) when is_binary(dataset_name) do
    {:ok, dataset_name, Map.get(ref, "inputs", %{})}
  end

  defp dataset_ref(name, _ref), do: {:error, "datasetRef #{name} must define dataset"}

  defp fetch_dataset(name, provisioned_datasets) do
    case Map.fetch(provisioned_datasets, name) do
      {:ok, dataset} -> {:ok, dataset}
      :error -> {:error, "dashboard references unknown dataset #{inspect(name)}"}
    end
  end

  defp yaml_files(dir), do: dir |> do_yaml_files() |> Enum.sort()

  defp do_yaml_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> do_yaml_files(path)
            String.ends_with?(entry, [".yaml", ".yml"]) -> [path]
            true -> []
          end
        end)

      {:error, :enoent} ->
        []
    end
  end

  defp put_metadata(config, root, path, folder_override) when is_map(config) do
    Map.put(config, "_meta", %{
      "path" => path,
      "folder" => folder(config, root, path, folder_override)
    })
  end

  defp put_variable_order(%{"variables" => variables} = dashboard, path) when is_map(variables) do
    order = variable_order(path)

    variables =
      Map.new(variables, fn {name, spec} ->
        spec =
          if is_map(spec),
            do: Map.put(spec, "_order", Enum.find_index(order, &(&1 == name))),
            else: spec

        {name, spec}
      end)

    Map.put(dashboard, "variables", variables)
  end

  defp put_variable_order(dashboard, _path), do: dashboard

  defp variable_order(path) do
    case File.read(path) do
      {:ok, content} -> extract_section_keys(content, "variables")
      {:error, _reason} -> []
    end
  end

  defp extract_section_keys(content, section) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &(String.trim(&1) == "#{section}:")) do
      nil ->
        []

      index ->
        section_indent = line_indent(Enum.at(lines, index))

        lines
        |> Enum.drop(index + 1)
        |> Enum.reduce_while([], fn line, acc ->
          trimmed = String.trim(line)
          indent = line_indent(line)

          cond do
            trimmed == "" or String.starts_with?(trimmed, "#") ->
              {:cont, acc}

            indent <= section_indent ->
              {:halt, acc}

            indent == section_indent + 2 and String.ends_with?(trimmed, ":") ->
              {:cont, [String.trim_trailing(trimmed, ":") | acc]}

            true ->
              {:cont, acc}
          end
        end)
        |> Enum.reverse()
    end
  end

  defp line_indent(line) do
    line
    |> String.length()
    |> Kernel.-(String.length(String.trim_leading(line)))
  end

  defp folder(config, root, path, folder_override) do
    config_folder = Map.get(config, "folder")

    cond do
      valid_folder?(config_folder) -> config_folder
      valid_folder?(folder_override) -> folder_override
      true -> filesystem_folder(root, path)
    end
  end

  defp filesystem_folder(root, path) do
    path
    |> Path.dirname()
    |> Path.relative_to(root)
    |> case do
      "." -> "root"
      folder -> folder
    end
  end

  defp valid_folder?(folder), do: is_binary(folder) and folder != ""

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, document} -> {:ok, document || %{}}
      {:error, reason} -> {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end
end
