defmodule ObserveWeb.DatasourceShowLive do
  use ObserveWeb, :live_view

  alias Observe.Store

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Store.get_datasource(name) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Datasource #{name} was not found")
         |> push_navigate(to: ~p"/datasources")}

      datasource ->
        {:ok, assign(socket, name: name, datasource: datasource)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="datasource-show" class="space-y-6">
        <div class="mocha-shell sharp-corner p-8 md:p-10">
          <.link
            navigate={~p"/datasources"}
            class="text-sm font-semibold text-[#89dceb] transition hover:text-[#f5c2e7]"
          >
            Back to datasources
          </.link>
          <div class="mt-5 flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <p class="mocha-label text-sm font-semibold uppercase tracking-[0.3em]">
                Datasource
              </p>
              <h1 class="mocha-heading mt-3 text-5xl font-semibold tracking-tight md:text-6xl">
                {@name}
              </h1>
              <p class="mocha-muted mt-4 max-w-2xl text-lg leading-8">
                Provisioned datasource configuration loaded from YAML.
              </p>
            </div>
            <div class="border border-[#a6e3a1]/20 bg-[#a6e3a1]/10 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#a6e3a1]">Type</p>
              <p class="mt-2 text-3xl font-semibold text-[#cdd6f4]">
                {Map.get(@datasource, "type", "unknown")}
              </p>
            </div>
          </div>
        </div>

        <div class="grid gap-5 xl:grid-cols-[1fr_1.2fr]">
          <section class="mocha-card sharp-corner p-5">
            <h2 class="text-lg font-semibold text-[#cdd6f4]">Configuration</h2>
            <dl class="mt-5 divide-y divide-[#45475a]/50 border border-[#b4befe]/12 bg-[#11111b]/35">
              <div
                :for={{key, value} <- visible_config(@datasource)}
                class="grid grid-cols-[9rem_1fr] gap-4 px-4 py-3 text-sm"
              >
                <dt class="font-semibold text-[#89dceb]">{key}</dt>
                <dd class="min-w-0 break-words text-[#cdd6f4]">{format_value(value)}</dd>
              </div>
            </dl>
          </section>

          <section class="mocha-card sharp-corner p-5">
            <h2 class="text-lg font-semibold text-[#cdd6f4]">Provisioning Metadata</h2>
            <dl class="mt-5 divide-y divide-[#45475a]/50 border border-[#b4befe]/12 bg-[#11111b]/35">
              <div
                :for={{key, value} <- metadata(@datasource)}
                class="grid grid-cols-[9rem_1fr] gap-4 px-4 py-3 text-sm"
              >
                <dt class="font-semibold text-[#f9e2af]">{key}</dt>
                <dd class="min-w-0 break-words text-[#bac2de]">{format_value(value)}</dd>
              </div>
            </dl>
          </section>
        </div>

        <section class="mocha-card sharp-corner p-5">
          <h2 class="text-lg font-semibold text-[#cdd6f4]">Raw YAML Model</h2>
          <pre
            phx-no-curly-interpolation
            class="mocha-code mt-4 overflow-x-auto p-5 text-sm leading-7"
          ><code><%= inspect(@datasource, pretty: true, limit: :infinity) %></code></pre>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp visible_config(datasource) do
    datasource
    |> Map.drop(["_meta"])
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp metadata(datasource),
    do: datasource |> Map.get("_meta", %{}) |> Enum.sort_by(fn {key, _value} -> key end)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
