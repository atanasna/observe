defmodule Observe.Provisioning do
  @moduledoc """
  Loads YAML-provisioned datasources, queries, and dashboards.
  """

  alias Observe.QueryGraph
  alias Observe.Variables

  @datasource_dir Path.expand("../../config/datasources", __DIR__)
  @query_dir Path.expand("../../config/queries", __DIR__)
  @dashboard_dir Path.expand("../../config/dashboards", __DIR__)

  def load do
    with {:ok, datasources} <- load_datasources(),
         {:ok, queries} <- load_queries(),
         {:ok, dashboards} <- load_dashboards(datasources, queries) do
      {:ok, %{datasources: datasources, queries: queries, dashboards: dashboards}}
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

  def load_dashboards(datasources, queries \\ %{}, dir \\ @dashboard_dir) do
    dir
    |> yaml_files()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case read_yaml(path) do
        {:ok, dashboard} ->
          with {:ok, normalized} <- normalize_dashboard(dashboard, path),
               {:ok, resolved} <- resolve_dashboard_queries(normalized, queries),
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

  defp normalize_dashboard(%{"kind" => "Dashboard"} = dashboard, _path) do
    name = get_in(dashboard, ["metadata", "name"])

    cond do
      not is_binary(name) or name == "" ->
        {:error, "dashboard metadata.name is required"}

      not is_map(Map.get(dashboard, "queries", %{})) ->
        {:error, "dashboard queries must be a map"}

      not is_list(Map.get(dashboard, "queryRefs", [])) ->
        {:error, "dashboard queryRefs must be a list"}

      not is_map(Map.get(dashboard, "datasets", %{})) ->
        {:error, "dashboard datasets must be a map"}

      not is_list(Map.get(dashboard, "panels", [])) ->
        {:error, "dashboard panels must be a list"}

      true ->
        {:ok,
         dashboard
         |> Map.put_new("variables", %{})
         |> Map.put_new("datasources", %{})
         |> Map.put_new("queryRefs", [])
         |> Map.put_new("queries", %{})
         |> Map.put_new("datasets", %{})
         |> Map.put_new("panels", [])}
    end
  end

  defp normalize_dashboard(_dashboard, _path), do: {:error, "kind must be Dashboard"}

  defp resolve_dashboard_queries(dashboard, provisioned_queries) do
    with {:ok, referenced_queries} <-
           referenced_queries(Map.get(dashboard, "queryRefs", []), provisioned_queries) do
      {:ok,
       Map.put(
         dashboard,
         "queries",
         Map.merge(referenced_queries, Map.get(dashboard, "queries", %{}))
       )}
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
