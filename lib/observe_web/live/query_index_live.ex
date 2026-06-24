defmodule ObserveWeb.QueryIndexLive do
  use ObserveWeb, :live_view

  alias Observe.Store

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, queries: Store.list_queries(), collapsed_folders: MapSet.new())}
  end

  @impl true
  def handle_event("toggle_folder", %{"path" => path}, socket) do
    {:noreply,
     assign(socket, :collapsed_folders, toggle_path(socket.assigns.collapsed_folders, path))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="query-index" class="space-y-6">
        <div class="mocha-shell sharp-corner p-8 md:p-10">
          <p class="mocha-label text-sm font-semibold uppercase tracking-[0.3em]">Inventory</p>
          <div class="mt-4 flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="mocha-heading text-5xl font-semibold tracking-tight md:text-6xl">
                Queries
              </h1>
              <p class="mocha-muted mt-5 max-w-2xl text-lg leading-8">
                First-class query definitions loaded from provisioning folders and reusable across dashboards and panels.
              </p>
            </div>
            <div class="border border-[#a6e3a1]/20 bg-[#a6e3a1]/10 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#a6e3a1]">
                Loaded queries
              </p>
              <p class="mt-2 text-3xl font-semibold text-[#cdd6f4]">{length(@queries)}</p>
            </div>
          </div>
        </div>

        <div id="query-tree" class="mocha-card sharp-corner p-5">
          <div
            :if={@queries == []}
            class="border border-dashed border-[#b4befe]/20 p-8 text-[#bac2de]"
          >
            No queries found in <code>config/queries</code>.
          </div>

          <div :if={@queries != []} class="border border-[#b4befe]/12 bg-[#11111b]/35">
            <div class="grid grid-cols-[1fr_8rem_1fr] border-b border-[#b4befe]/12 px-4 py-3 text-xs font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
              <span>Provisioning Tree</span>
              <span>Kind</span>
              <span>Definition</span>
            </div>
            <div class="divide-y divide-[#45475a]/50">
              <%= for row <- query_tree_rows(@queries, @collapsed_folders) do %>
                <div
                  :if={row.kind == :folder}
                  id={"query-folder-#{Enum.join(row.path, "-")}"}
                  class="tree-clickable grid grid-cols-[1fr_8rem_1fr] items-center px-4 py-3 text-sm transition"
                >
                  <button
                    type="button"
                    phx-click="toggle_folder"
                    phx-value-path={path_key(row.path)}
                    class="flex items-center gap-3 text-left"
                    style={"padding-left: #{row.depth * 1.25}rem"}
                  >
                    <span class="tree-arrow w-5 text-xl leading-none text-[#f9e2af]">
                      {if row.collapsed, do: "▸", else: "▾"}
                    </span>
                    <span class="font-semibold text-[#cdd6f4]">{row.name}</span>
                  </button>
                  <span class="text-[#6c7086]">-</span>
                  <span class="truncate text-[#6c7086]">-</span>
                </div>

                <a
                  :if={row.kind == :query}
                  id={"query-node-#{row.name}"}
                  href={~p"/queries/#{row.name}"}
                  phx-click={JS.navigate(~p"/queries/#{row.name}")}
                  class="tree-clickable grid grid-cols-[1fr_8rem_1fr] items-center px-4 py-3 text-sm transition"
                >
                  <div
                    class="flex min-w-0 items-center gap-3"
                    style={"padding-left: #{row.depth * 1.25}rem"}
                  >
                    <span class="tree-arrow text-[#89dceb]">└</span>
                    <div class="min-w-0">
                      <p class="truncate font-semibold text-[#cdd6f4]">{row.name}</p>
                      <p class="mt-1 truncate text-xs text-[#9399b2]">
                        {get_in(row.query, ["_meta", "folder"]) || "root"}
                      </p>
                    </div>
                  </div>
                  <span class="w-fit border border-[#f9e2af]/20 bg-[#f9e2af]/10 px-2 py-1 text-xs font-semibold text-[#f9e2af]">
                    {query_kind(row.query)}
                  </span>
                  <span class="truncate text-[#bac2de]">{query_summary(row.query)}</span>
                </a>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp query_tree_rows(queries, collapsed_folders) do
    folders = queries |> Enum.map(fn {_name, query} -> folder_parts(query) end) |> Enum.uniq()

    []
    |> build_query_rows(folders, queries)
    |> visible_rows(collapsed_folders, :query)
    |> Enum.map(&put_collapsed(&1, collapsed_folders))
  end

  defp build_query_rows(prefix, folders, queries) do
    child_folders =
      folders
      |> Enum.filter(&(Enum.take(&1, length(prefix)) == prefix and length(&1) > length(prefix)))
      |> Enum.map(&Enum.at(&1, length(prefix)))
      |> Enum.uniq()
      |> Enum.sort()

    folder_rows =
      Enum.flat_map(child_folders, fn name ->
        path = prefix ++ [name]

        [
          %{kind: :folder, name: name, path: path, depth: length(prefix)}
          | build_query_rows(path, folders, queries)
        ]
      end)

    leaf_rows =
      queries
      |> Enum.filter(fn {_name, query} -> folder_parts(query) == prefix end)
      |> Enum.sort_by(fn {name, _query} -> name end)
      |> Enum.map(fn {name, query} ->
        %{
          kind: :query,
          name: name,
          query: query,
          path: folder_parts(query),
          depth: length(prefix)
        }
      end)

    folder_rows ++ leaf_rows
  end

  defp folder_parts(query) do
    query
    |> get_in(["_meta", "folder"])
    |> case do
      nil -> ["root"]
      "root" -> ["root"]
      folder -> String.split(folder, "/", trim: true)
    end
  end

  defp query_kind(query) do
    cond do
      Map.has_key?(query, "datasource") -> "source"
      Map.has_key?(query, "from") -> "derived"
      true -> "unknown"
    end
  end

  defp query_summary(%{"datasource" => datasource, "request" => request}) do
    request_query = get_in(request, ["query"])
    if is_binary(request_query), do: "#{datasource}: #{request_query}", else: datasource
  end

  defp query_summary(%{"from" => from}), do: "from #{from}"
  defp query_summary(_query), do: "-"

  defp visible_rows(rows, collapsed_folders, leaf_kind) do
    Enum.reject(rows, &hidden_by_collapsed_folder?(&1, collapsed_folders, leaf_kind))
  end

  defp hidden_by_collapsed_folder?(%{kind: :folder, path: path}, collapsed_folders, _leaf_kind) do
    path
    |> parent_paths()
    |> Enum.any?(&MapSet.member?(collapsed_folders, path_key(&1)))
  end

  defp hidden_by_collapsed_folder?(%{kind: leaf_kind, path: path}, collapsed_folders, leaf_kind) do
    path
    |> prefixes()
    |> Enum.any?(&MapSet.member?(collapsed_folders, path_key(&1)))
  end

  defp put_collapsed(%{kind: :folder, path: path} = row, collapsed_folders) do
    Map.put(row, :collapsed, MapSet.member?(collapsed_folders, path_key(path)))
  end

  defp put_collapsed(row, _collapsed_folders), do: row

  defp toggle_path(collapsed_folders, path) do
    if MapSet.member?(collapsed_folders, path) do
      MapSet.delete(collapsed_folders, path)
    else
      MapSet.put(collapsed_folders, path)
    end
  end

  defp parent_paths(path) do
    path
    |> prefixes()
    |> Enum.drop(-1)
  end

  defp prefixes(path), do: Enum.map(1..length(path)//1, &Enum.take(path, &1))
  defp path_key(path), do: Enum.join(path, "/")
end
