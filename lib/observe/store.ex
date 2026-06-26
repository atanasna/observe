defmodule Observe.Store do
  @moduledoc """
  In-memory registry for provisioned dashboards, datasources, and queries.
  """
  use GenServer

  alias Observe.Provisioning

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def list_dashboards, do: GenServer.call(__MODULE__, :list_dashboards)

  def list_queries, do: GenServer.call(__MODULE__, :list_queries)

  def list_datasources, do: GenServer.call(__MODULE__, :list_datasources)

  def get_datasource(name), do: GenServer.call(__MODULE__, {:get_datasource, name})

  def get_dashboard(name), do: GenServer.call(__MODULE__, {:get_dashboard, name})

  def get_query(name), do: GenServer.call(__MODULE__, {:get_query, name})

  def datasources, do: GenServer.call(__MODULE__, :datasources)

  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_opts) do
    {:ok, load_state()}
  end

  @impl true
  def handle_call(:list_dashboards, _from, state) do
    state = reload_if_failed(state)

    dashboards =
      state.dashboards
      |> Map.values()
      |> Enum.sort_by(&get_in(&1, ["metadata", "name"]))

    {:reply, dashboards, state}
  end

  def handle_call({:get_dashboard, name}, _from, state) do
    state = reload_if_failed(state)
    {:reply, Map.get(state.dashboards, name), state}
  end

  def handle_call({:get_query, name}, _from, state) do
    state = reload_if_failed(state)
    {:reply, Map.get(state.queries, name), state}
  end

  def handle_call({:get_datasource, name}, _from, state) do
    state = reload_if_failed(state)
    {:reply, Map.get(state.datasources, name), state}
  end

  def handle_call(:list_datasources, _from, state) do
    state = reload_if_failed(state)

    datasources =
      state.datasources
      |> Enum.map(fn {name, config} -> {name, config} end)
      |> Enum.sort_by(fn {name, config} ->
        {get_in(config, ["_meta", "folder"]) || "root", name}
      end)

    {:reply, datasources, state}
  end

  def handle_call(:list_queries, _from, state) do
    state = reload_if_failed(state)

    queries =
      state.queries
      |> Enum.map(fn {name, query} -> {name, query} end)
      |> Enum.sort_by(fn {name, query} ->
        {get_in(query, ["_meta", "folder"]) || "root", name}
      end)

    {:reply, queries, state}
  end

  def handle_call(:datasources, _from, state) do
    state = reload_if_failed(state)
    {:reply, state.datasources, state}
  end

  def handle_call(:reload, _from, _state) do
    state = load_state()
    {:reply, state, state}
  end

  defp load_state do
    case Provisioning.load() do
      {:ok, state} ->
        state

      {:error, reason} ->
        %{datasources: %{}, queries: %{}, processors: %{}, dashboards: %{}, error: reason}
    end
  end

  defp reload_if_failed(%{error: _reason}), do: load_state()
  defp reload_if_failed(state), do: state
end
