defmodule ObserveWeb.DatasourceIndexLive do
  use ObserveWeb, :live_view

  alias Observe.Store

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, datasources: Store.list_datasources(), collapsed_folders: MapSet.new())}
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
      <section id="datasource-index" class="space-y-6">
        <div class="mocha-shell sharp-corner p-8 md:p-10">
          <p class="mocha-label text-sm font-semibold uppercase tracking-[0.3em]">Inventory</p>
          <div class="mt-4 flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="mocha-heading text-5xl font-semibold tracking-tight md:text-6xl">
                Datasources
              </h1>
              <p class="mocha-muted mt-5 max-w-2xl text-lg leading-8">
                Physical datasource refs loaded recursively from provisioning folders.
              </p>
            </div>
            <div class="border border-[#b4befe]/16 bg-[#11111b]/35 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#f9e2af]">
                Loaded refs
              </p>
              <p class="mt-2 text-3xl font-semibold text-[#cdd6f4]">{length(@datasources)}</p>
            </div>
          </div>
        </div>

        <div id="datasource-tree" class="mocha-card sharp-corner p-5">
          <div
            :if={@datasources == []}
            class="border border-dashed border-[#b4befe]/20 p-8 text-[#bac2de]"
          >
            No datasources found in <code>config/datasources</code>.
          </div>

          <div :if={@datasources != []} class="border border-[#b4befe]/12 bg-[#11111b]/35">
            <div class="grid grid-cols-[1fr_8rem_1fr] border-b border-[#b4befe]/12 px-4 py-3 text-xs font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
              <span>Provisioning Tree</span>
              <span>Type</span>
              <span>Endpoint / Region</span>
            </div>
            <div class="divide-y divide-[#45475a]/50">
              <%= for row <- datasource_tree_rows(@datasources, @collapsed_folders) do %>
                <div
                  :if={row.kind == :folder}
                  id={"datasource-folder-#{Enum.join(row.path, "-")}"}
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
                  :if={row.kind == :datasource}
                  id={"datasource-node-#{row.name}"}
                  href={~p"/datasources/#{row.name}"}
                  phx-click={JS.navigate(~p"/datasources/#{row.name}")}
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
                        {get_in(row.config, ["_meta", "folder"]) || "root"}
                      </p>
                    </div>
                  </div>
                  <span class="w-fit border border-[#a6e3a1]/20 bg-[#a6e3a1]/10 px-2 py-1 text-xs font-semibold text-[#a6e3a1]">
                    {Map.get(row.config, "type", "unknown")}
                  </span>
                  <span class="truncate text-[#bac2de]">{datasource_endpoint(row.config)}</span>
                </a>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp datasource_tree_rows(datasources, collapsed_folders) do
    folders =
      datasources |> Enum.map(fn {_name, config} -> folder_parts(config) end) |> Enum.uniq()

    []
    |> build_datasource_rows(folders, datasources)
    |> visible_rows(collapsed_folders, :datasource)
    |> Enum.map(&put_collapsed(&1, collapsed_folders))
  end

  defp build_datasource_rows(prefix, folders, datasources) do
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
          | build_datasource_rows(path, folders, datasources)
        ]
      end)

    leaf_rows =
      datasources
      |> Enum.filter(fn {_name, config} -> folder_parts(config) == prefix end)
      |> Enum.sort_by(fn {name, _config} -> name end)
      |> Enum.map(fn {name, config} ->
        %{
          kind: :datasource,
          name: name,
          config: config,
          path: folder_parts(config),
          depth: length(prefix)
        }
      end)

    folder_rows ++ leaf_rows
  end

  defp folder_parts(config) do
    config
    |> get_in(["_meta", "folder"])
    |> case do
      nil -> ["root"]
      "root" -> ["root"]
      folder -> String.split(folder, "/", trim: true)
    end
  end

  defp datasource_endpoint(config), do: Map.get(config, "url") || Map.get(config, "region") || "-"

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
