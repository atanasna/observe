defmodule ObserveWeb.DashboardShowLive do
  use ObserveWeb, :live_view

  alias Observe.Executor
  alias Observe.PanelCompatibility
  alias Observe.Store
  alias Observe.TimeRange
  alias Observe.Variables

  @var_ref_regex ~r/\$\{vars\.([A-Za-z0-9_\-]+)(?:\.[A-Za-z0-9_\-]+)*\}/

  @impl true
  def mount(%{"name" => name} = params, _session, socket) do
    case Store.get_dashboard(name) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Dashboard #{name} was not found")
         |> push_navigate(to: ~p"/dashboards")}

      dashboard ->
        datasources = Store.datasources()

        {variable_values, variable_options} =
          Variables.merge_with_options(Map.get(dashboard, "variables", %{}), params, datasources)

        time_range_preset = TimeRange.default()
        time_range = TimeRange.range(time_range_preset)
        datetime_values = TimeRange.datetime_local(time_range)

        {:ok,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:datasources, datasources)
         |> assign(:variable_values, variable_values)
         |> assign(:variable_options, variable_options)
         |> assign(:start_time, datetime_values.start)
         |> assign(:end_time, datetime_values.end)
         |> assign(:time_range_preset, time_range_preset)
         |> assign(:refresh_interval, "off")
         |> assign(:refresh_timer, nil)
         |> assign(:run_ref, nil)
         |> assign(:run_id, nil)
         |> assign(:loading?, false)
         |> assign(:loading_datasets, MapSet.new())
         |> assign(:collapsed_sections, collapsed_sections(dashboard))
         |> assign(:plan, nil)
         |> assign(:datasets, %{})
         |> assign(:error, nil)
         |> start_dashboard_run(variable_values)}
    end
  end

  @impl true
  def handle_event(
        "variables_changed",
        %{"_target" => ["variables", "source"], "variables" => params},
        socket
      ) do
    {variable_values, variable_options, source_value} =
      fast_source_variable_update(socket, params)

    load_deployment_options_async(socket, params, source_value)

    {:noreply,
     socket
     |> assign(:variable_values, variable_values)
     |> assign(:variable_options, variable_options)}
  end

  def handle_event("variables_changed", %{"variables" => params}, socket) do
    {variable_values, variable_options} =
      Variables.merge_with_options(
        Map.get(socket.assigns.dashboard, "variables", %{}),
        params,
        socket.assigns.datasources
      )

    socket =
      socket
      |> assign(:variable_options, variable_options)
      |> start_variable_dashboard_run(variable_values)

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> sync_relative_time_fields()
     |> start_dashboard_run(socket.assigns.variable_values)}
  end

  def handle_event("select_time_range", %{"range" => range}, socket) do
    if relative_time_range?(range) do
      datetime_values = range |> TimeRange.range() |> TimeRange.datetime_local()

      socket =
        socket
        |> assign(:start_time, datetime_values.start)
        |> assign(:end_time, datetime_values.end)
        |> assign(:time_range_preset, range)
        |> start_dashboard_run(socket.assigns.variable_values)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_panel_section", %{"id" => id}, socket) do
    collapsed_sections =
      if MapSet.member?(socket.assigns.collapsed_sections, id) do
        MapSet.delete(socket.assigns.collapsed_sections, id)
      else
        MapSet.put(socket.assigns.collapsed_sections, id)
      end

    {:noreply, assign(socket, :collapsed_sections, collapsed_sections)}
  end

  def handle_event("controls_changed", %{"controls" => controls}, socket) do
    start_time = valid_datetime(controls, "start_time", socket.assigns.start_time)
    end_time = valid_datetime(controls, "end_time", socket.assigns.end_time)

    time_range_preset =
      if start_time == socket.assigns.start_time and end_time == socket.assigns.end_time do
        socket.assigns.time_range_preset
      else
        "custom"
      end

    socket =
      socket
      |> assign(:start_time, start_time)
      |> assign(:end_time, end_time)
      |> assign(:time_range_preset, time_range_preset)
      |> assign(
        :refresh_interval,
        Map.get(controls, "refresh_interval", socket.assigns.refresh_interval)
      )
      |> reset_refresh_timer()
      |> start_dashboard_run(socket.assigns.variable_values)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:settle_variables, params}, socket) do
    {variable_values, variable_options} =
      Variables.merge_with_options(
        Map.get(socket.assigns.dashboard, "variables", %{}),
        params,
        socket.assigns.datasources
      )

    socket =
      socket
      |> assign(:variable_options, variable_options)
      |> start_dashboard_run(variable_values)

    {:noreply, socket}
  end

  def handle_info({:deployment_options_loaded, source_value, params, deployment_options}, socket) do
    if socket.assigns.variable_values["source"] == source_value do
      variables = Map.get(socket.assigns.dashboard, "variables", %{})
      deployment_spec = Map.get(variables, "deployment", %{})

      deployment_value =
        selected_variable_value(
          Map.get(params, "deployment"),
          deployment_spec,
          deployment_options
        )

      params = Map.put(params, "deployment", deployment_value)

      send(self(), {:settle_variables, params})

      {:noreply,
       socket
       |> assign(
         :variable_values,
         Map.put(socket.assigns.variable_values, "deployment", deployment_value)
       )
       |> assign(
         :variable_options,
         Map.put(socket.assigns.variable_options, "deployment", deployment_options)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:poll_dashboard, socket) do
    socket =
      socket
      |> sync_relative_time_fields()
      |> start_dashboard_run(socket.assigns.variable_values)
      |> schedule_refresh_timer()

    {:noreply, socket}
  end

  def handle_info({:dashboard_plan, run_id, plan}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, assign(socket, :plan, plan)}
  end

  def handle_info(
        {:dashboard_dataset, run_id, name, rows},
        %{assigns: %{run_id: run_id}} = socket
      ) do
    {:noreply, update(socket, :datasets, &Map.put(&1, name, rows))}
  end

  def handle_info({:dashboard_complete, run_id}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, socket |> assign(:loading?, false) |> assign(:loading_datasets, MapSet.new())}
  end

  def handle_info({:dashboard_plan, _run_id, _plan}, socket), do: {:noreply, socket}

  def handle_info({:dashboard_dataset, _run_id, _name, _rows}, socket), do: {:noreply, socket}

  def handle_info({:dashboard_complete, _run_id}, socket), do: {:noreply, socket}

  def handle_info({ref, result}, %{assigns: %{run_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        :ok ->
          socket
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:plan, nil)
          |> assign(:datasets, %{})
          |> assign(:loading_datasets, MapSet.new())
          |> assign(:error, reason)
      end

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:loading_datasets, MapSet.new())
     |> assign(:run_ref, nil)
     |> assign(:run_id, nil)}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref), do: {:noreply, socket}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{run_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:loading_datasets, MapSet.new())
     |> assign(:run_ref, nil)
     |> assign(:run_id, nil)
     |> assign(:error, "dashboard run failed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  defp start_dashboard_run(socket, variable_values),
    do: start_dashboard_run(socket, variable_values, :all)

  defp start_dashboard_run(socket, variable_values, only) do
    caller = self()
    run_id = make_ref()

    opts =
      %{
        time_range: selected_time_range(socket)
      }
      |> maybe_put_only(only)

    task =
      start_query_task(fn ->
        Executor.run_stream(socket.assigns.dashboard, variable_values, opts, fn
          {:plan, plan} -> send(caller, {:dashboard_plan, run_id, plan})
          {:dataset, name, rows} -> send(caller, {:dashboard_dataset, run_id, name, rows})
          :complete -> send(caller, {:dashboard_complete, run_id})
        end)
      end)

    socket
    |> assign(:variable_values, variable_values)
    |> assign(:loading?, true)
    |> assign(:loading_datasets, loading_datasets(only))
    |> assign(:run_ref, task.ref)
    |> assign(:run_id, run_id)
    |> assign(:plan, nil)
    |> maybe_clear_datasets(only)
    |> assign(:error, nil)
  end

  defp maybe_put_only(opts, :all), do: opts
  defp maybe_put_only(opts, only), do: Map.put(opts, :only, only)

  defp loading_datasets(:all), do: nil
  defp loading_datasets(only), do: MapSet.new(only)

  defp maybe_clear_datasets(socket, :all), do: assign(socket, :datasets, %{})

  defp maybe_clear_datasets(socket, only), do: update(socket, :datasets, &Map.drop(&1, only))

  defp start_variable_dashboard_run(socket, variable_values) do
    changed_vars = changed_variables(socket.assigns.variable_values, variable_values)

    cond do
      MapSet.size(changed_vars) == 0 ->
        assign(socket, :variable_values, variable_values)

      MapSet.member?(changed_vars, "source") ->
        start_dashboard_run(socket, variable_values)

      true ->
        affected = affected_datasets(socket.assigns.dashboard, changed_vars)

        if affected == [] do
          assign(socket, :variable_values, variable_values)
        else
          start_dashboard_run(socket, variable_values, affected)
        end
    end
  end

  defp changed_variables(previous, current) do
    previous
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.reduce(MapSet.new(), fn name, changed ->
      if Map.get(previous, name) == Map.get(current, name) do
        changed
      else
        MapSet.put(changed, name)
      end
    end)
  end

  defp affected_datasets(dashboard, changed_vars) do
    datasets = Map.get(dashboard, "datasets", %{})

    datasets
    |> Enum.filter(fn {_name, dataset} -> depends_on_changed_var?(dataset, changed_vars) end)
    |> Enum.map(fn {name, _dataset} -> name end)
    |> MapSet.new()
    |> include_dependent_datasets(datasets)
    |> MapSet.to_list()
  end

  defp include_dependent_datasets(affected, datasets) do
    next =
      Enum.reduce(datasets, affected, fn {name, dataset}, acc ->
        parent = source_dataset_name(dataset) || Map.get(dataset, "from")

        if is_binary(parent) and MapSet.member?(acc, parent) do
          MapSet.put(acc, name)
        else
          acc
        end
      end)

    if MapSet.equal?(next, affected),
      do: affected,
      else: include_dependent_datasets(next, datasets)
  end

  defp depends_on_changed_var?(value, changed_vars) do
    value
    |> variable_refs()
    |> Enum.any?(&MapSet.member?(changed_vars, &1))
  end

  defp variable_refs(value) when is_binary(value) do
    @var_ref_regex
    |> Regex.scan(value)
    |> Enum.map(fn [_match, name] -> name end)
  end

  defp variable_refs(value) when is_map(value) do
    value
    |> Map.drop(["_meta"])
    |> Enum.flat_map(fn {_key, val} -> variable_refs(val) end)
  end

  defp variable_refs(value) when is_list(value), do: Enum.flat_map(value, &variable_refs/1)
  defp variable_refs(_value), do: []

  defp source_dataset_name(%{"source" => "dataset", "dataset" => %{"name" => name}}), do: name
  defp source_dataset_name(_dataset), do: nil

  defp start_query_task(fun) do
    ensure_query_task_supervisor!()
    Task.Supervisor.async_nolink(Observe.QueryTaskSupervisor, fun)
  end

  defp ensure_query_task_supervisor! do
    case Process.whereis(Observe.QueryTaskSupervisor) do
      nil ->
        case Task.Supervisor.start_link(name: Observe.QueryTaskSupervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp reset_refresh_timer(socket) do
    if socket.assigns.refresh_timer do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    socket
    |> assign(:refresh_timer, nil)
    |> schedule_refresh_timer()
  end

  defp schedule_refresh_timer(socket) do
    case refresh_ms(socket.assigns.refresh_interval) do
      nil ->
        socket

      ms ->
        assign(socket, :refresh_timer, Process.send_after(self(), :poll_dashboard, ms))
    end
  end

  defp refresh_ms("10s"), do: 10_000
  defp refresh_ms("30s"), do: 30_000
  defp refresh_ms("1m"), do: 60_000
  defp refresh_ms("5m"), do: 300_000
  defp refresh_ms(_interval), do: nil

  defp refresh_options do
    [{"↻", "off"}, {"10s", "10s"}, {"30s", "30s"}, {"1m", "1m"}, {"5m", "5m"}]
  end

  defp selected_time_range(%{assigns: %{time_range_preset: preset}} = socket)
       when preset != "custom" do
    TimeRange.range(preset)
  rescue
    _ -> TimeRange.custom!(socket.assigns.start_time, socket.assigns.end_time)
  end

  defp selected_time_range(socket) do
    TimeRange.custom!(socket.assigns.start_time, socket.assigns.end_time)
  end

  defp sync_relative_time_fields(%{assigns: %{time_range_preset: "custom"}} = socket), do: socket

  defp sync_relative_time_fields(%{assigns: %{time_range_preset: preset}} = socket) do
    datetime_values = preset |> TimeRange.range() |> TimeRange.datetime_local()

    socket
    |> assign(:start_time, datetime_values.start)
    |> assign(:end_time, datetime_values.end)
  end

  defp relative_time_range?(range) do
    Enum.any?(TimeRange.options(), fn {_label, value} -> value == range end)
  end

  defp time_range_button_label("custom", start_time, end_time) do
    "#{format_time_range_value(start_time)} to #{format_time_range_value(end_time)}"
  end

  defp time_range_button_label(preset, start_time, end_time) do
    case Enum.find_value(TimeRange.options(), fn {label, value} ->
           if value == preset, do: label
         end) do
      nil -> time_range_button_label("custom", start_time, end_time)
      label -> label
    end
  end

  defp format_time_range_value(value) do
    value
    |> String.replace("T", " ")
    |> String.replace(~r/:00$/, "")
  end

  defp fast_source_variable_update(socket, params) do
    variables = Map.get(socket.assigns.dashboard, "variables", %{})
    source_spec = Map.get(variables, "source", %{})

    source_options =
      Variables.select_options(
        source_spec,
        socket.assigns.datasources,
        socket.assigns.variable_values
      )

    source_value = selected_variable_value(Map.get(params, "source"), source_spec, source_options)

    variable_values =
      socket.assigns.variable_values
      |> Map.merge(params)
      |> Map.put("source", source_value)
      |> Map.put("deployment", "")

    variable_options =
      socket.assigns.variable_options
      |> Map.put("source", source_options)
      |> Map.put("deployment", [{"Loading deployments...", ""}])

    {variable_values, variable_options, source_value}
  end

  defp load_deployment_options_async(socket, params, source_value) do
    caller = self()
    variables = Map.get(socket.assigns.dashboard, "variables", %{})
    deployment_spec = Map.get(variables, "deployment", %{})
    datasources = socket.assigns.datasources
    vars = Map.put(socket.assigns.variable_values, "source", source_value)

    Task.start(fn ->
      deployment_options = Variables.select_options(deployment_spec, datasources, vars)
      send(caller, {:deployment_options_loaded, source_value, params, deployment_options})
    end)
  end

  defp selected_variable_value(requested_value, spec, options) do
    default = Map.get(spec, "default")
    values = Enum.map(options, fn {_label, value} -> value end)

    cond do
      values == [] -> requested_value || default
      requested_value in values -> requested_value
      default in values -> default
      true -> List.first(values)
    end
  end

  defp valid_datetime(controls, key, current_value) do
    value = Map.get(controls, key, current_value)

    if TimeRange.valid_datetime_local?(value), do: value, else: current_value
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumbs={dashboard_breadcrumbs(@dashboard)}>
      <section id="dashboard-show" class="space-y-3">
        <div class="dashboard-header-shell mocha-shell sharp-corner p-3 md:p-4">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h1 class="mocha-heading text-2xl font-semibold tracking-tight md:text-3xl">
                {get_in(@dashboard, ["metadata", "title"]) || get_in(@dashboard, ["metadata", "name"])}
              </h1>
              <p class="mocha-muted mt-1 text-xs">
                {map_size(Map.get(@dashboard, "queries", %{}))} query nodes · {length(
                  Map.get(@dashboard, "panels", [])
                )} panels
              </p>
            </div>
            <div class="flex flex-wrap items-end gap-2">
              <.form
                for={
                  to_form(%{
                    "controls" => %{
                      "start_time" => @start_time,
                      "end_time" => @end_time,
                      "refresh_interval" => @refresh_interval
                    }
                  })
                }
                id="dashboard-controls"
                phx-change="controls_changed"
                class="flex flex-wrap gap-2"
              >
                <details
                  id="dashboard-time-picker"
                  phx-hook="TimePicker"
                  class="dashboard-time-picker relative"
                >
                  <summary class="flex min-h-8 cursor-pointer list-none items-center gap-2 border border-[#b4befe]/20 bg-[#11111b]/70 px-3 py-1.5 text-xs font-semibold text-[#cdd6f4] shadow-lg shadow-black/10 transition hover:border-[#89dceb]/50 hover:bg-[#181825] [&::-webkit-details-marker]:hidden">
                    <.icon name="hero-clock-micro" class="size-4 text-[#89dceb]" />
                    <span>{time_range_button_label(@time_range_preset, @start_time, @end_time)}</span>
                    <.icon name="hero-chevron-down-micro" class="size-4 text-[#bac2de]" />
                  </summary>
                  <div class="absolute right-0 top-[calc(100%+0.5rem)] z-50 w-[min(92vw,40rem)] border border-[#89b4fa]/25 bg-[#11111b] text-[#cdd6f4] shadow-2xl shadow-black/50">
                    <div class="grid gap-0 md:grid-cols-[13rem_1fr]">
                      <div class="border-b border-[#b4befe]/15 bg-[#181825]/80 p-2 md:border-b-0 md:border-r">
                        <p class="px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                          Quick ranges
                        </p>
                        <button
                          :for={{label, value} <- TimeRange.options()}
                          type="button"
                          phx-click="select_time_range"
                          phx-value-range={value}
                          data-close-time-picker
                          class={[
                            "block w-full px-2 py-1.5 text-left text-xs font-semibold transition hover:bg-[#313244] hover:text-[#f5c2e7]",
                            @time_range_preset == value && "bg-[#313244] text-[#f5c2e7]"
                          ]}
                        >
                          {label}
                        </button>
                      </div>
                      <div class="space-y-3 p-3">
                        <div>
                          <p class="text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                            Absolute time range
                          </p>
                          <p class="mt-1 text-[0.7rem] text-[#bac2de]">
                            Set exact UTC start and end times.
                          </p>
                        </div>
                        <div class="grid gap-2 sm:grid-cols-2">
                          <div>
                            <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                              From
                            </label>
                            <input
                              id="dashboard-start-time"
                              type="datetime-local"
                              name="controls[start_time]"
                              value={@start_time}
                              class="w-full border border-[#b4befe]/15 bg-[#181825]/80 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#1e1e2e]"
                            />
                          </div>
                          <div>
                            <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                              To
                            </label>
                            <input
                              id="dashboard-end-time"
                              type="datetime-local"
                              name="controls[end_time]"
                              value={@end_time}
                              class="w-full border border-[#b4befe]/15 bg-[#181825]/80 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#1e1e2e]"
                            />
                          </div>
                        </div>
                        <div class="flex items-center justify-between border-t border-[#b4befe]/15 pt-3">
                          <span class="text-[0.7rem] font-semibold text-[#bac2de]">
                            Times are evaluated in UTC.
                          </span>
                          <button
                            type="button"
                            phx-click="refresh"
                            data-close-time-picker
                            class="border border-[#89dceb]/40 bg-[#89dceb] px-3 py-1.5 text-xs font-bold text-[#11111b] transition hover:bg-[#f5c2e7]"
                          >
                            Apply time range
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>
                </details>
                <div class="flex items-end">
                  <select
                    id="dashboard-refresh-interval"
                    name="controls[refresh_interval]"
                    aria-label="Refresh interval"
                    title="Refresh interval"
                    class="min-h-8 border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
                  >
                    <option
                      :for={{label, value} <- refresh_options()}
                      value={value}
                      selected={@refresh_interval == value}
                    >
                      {label}
                    </option>
                  </select>
                </div>
              </.form>
            </div>
          </div>

          <.form
            :if={map_size(Map.get(@dashboard, "variables", %{})) > 0}
            for={to_form(%{"variables" => @variable_values})}
            id="dashboard-variables"
            phx-change="variables_changed"
            class="mt-3 grid gap-2 md:grid-cols-4 xl:grid-cols-6"
          >
            <div :for={{name, spec} <- Variables.ordered(Map.get(@dashboard, "variables", %{}))}>
              <label
                for={"variables_#{name}"}
                class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]"
              >
                {name}
              </label>
              <select
                id={"variables_#{name}"}
                name={"variables[#{name}]"}
                class="w-full border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
              >
                <option
                  :for={{label, value} <- Map.get(@variable_options, name, [])}
                  value={value}
                  selected={@variable_values[name] == value}
                >
                  {label}
                </option>
              </select>
            </div>
          </.form>
        </div>

        <div
          :if={@error}
          id="dashboard-error"
          class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold text-[#f38ba8]"
        >
          {@error}
        </div>

        <div
          id="panel-grid"
          class="panel-grid grid gap-3"
          style={"--panel-columns: #{dashboard_columns(@dashboard)}"}
        >
          <article
            :for={panel <- visible_panels(@dashboard, @collapsed_sections)}
            id={"panel-#{panel["id"]}"}
            data-section-collapsed={section_collapsed_attr(panel, @collapsed_sections)}
            data-stacked={stacked_attr(panel)}
            data-legend-position={legend_position(panel)}
            data-layout-width={panel_width(panel, @dashboard)}
            data-layout-height={panel_height(panel, 160)}
            style={"--panel-width: #{panel_width(panel, @dashboard)}"}
            class={[
              if(panel["type"] == "row",
                do: "py-2",
                else: "mocha-card sharp-corner p-3 transition duration-300"
              )
            ]}
          >
            <div :if={panel["type"] != "row"} class="mb-2 flex items-center gap-1.5">
              <h2 class="text-sm font-semibold text-[#cdd6f4]">
                {panel_title(panel, @dashboard, @variable_values, @datasources)}
              </h2>
              <span
                :if={panel_description(panel, @dashboard, @variable_values, @datasources)}
                class="group relative inline-flex items-center"
              >
                <button
                  type="button"
                  aria-label="Panel description"
                  class="grid size-5 place-items-center text-[#89dceb]/80 transition hover:text-[#f5c2e7] focus:outline-none focus:text-[#f5c2e7]"
                >
                  <.icon name="hero-information-circle-micro" class="size-4" />
                </button>
                <span class="pointer-events-none absolute left-1/2 top-5 z-20 hidden w-64 -translate-x-1/2 border border-[#89dceb]/25 bg-[#11111b]/95 px-3 py-2 text-xs font-medium leading-5 text-[#cdd6f4] shadow-xl shadow-[#000]/30 group-hover:block group-focus-within:block">
                  {panel_description(panel, @dashboard, @variable_values, @datasources)}
                </span>
              </span>
            </div>

            <%= if panel_loading?(panel, @datasets, @loading?, @loading_datasets) do %>
              <div class="flex min-h-28 items-center justify-center gap-3 border border-[#89dceb]/20 bg-[#89dceb]/10 p-4 text-xs font-semibold uppercase tracking-[0.16em] text-[#89dceb]">
                <span class="inline-block size-4 animate-spin rounded-full border-2 border-[#89dceb]/25 border-t-[#89dceb]" />
                Loading dataset
              </div>
            <% else %>
              <%= if error = panel_error(panel, @datasets, @dashboard) do %>
                <div class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold leading-5 text-[#f38ba8]">
                  {error}
                </div>
              <% else %>
                <%= case panel["type"] do %>
                  <% "row" -> %>
                    <button
                      id={"section-toggle-#{panel["id"]}"}
                      type="button"
                      phx-click="toggle_panel_section"
                      phx-value-id={panel["id"]}
                      aria-expanded={!section_collapsed?(panel, @collapsed_sections) |> to_string()}
                      class="flex w-full items-center gap-3 text-left text-xs font-semibold uppercase tracking-[0.18em] text-[#cba6f7] focus:outline-none"
                    >
                      <span class="h-px flex-1 bg-[#45475a]/70"></span>
                      <span class="shrink-0">
                        {panel_title(panel, @dashboard, @variable_values, @datasources)}
                      </span>
                      <.icon
                        name={
                          if section_collapsed?(panel, @collapsed_sections),
                            do: "hero-chevron-right-micro",
                            else: "hero-chevron-down-micro"
                        }
                        class="size-4 shrink-0 text-[#cba6f7]"
                      />
                      <span class="h-px flex-1 bg-[#45475a]/70"></span>
                    </button>
                  <% "stat" -> %>
                    <div class="sharp-corner bg-gradient-to-br from-[#cba6f7] via-[#89b4fa] to-[#94e2d5] p-4 text-[#11111b]">
                      <p class="text-xs font-semibold uppercase tracking-[0.18em] opacity-70">Rows</p>
                      <p class="mt-1 text-4xl font-semibold tracking-tight">
                        {length(panel_rows(panel, @datasets, @dashboard))}
                      </p>
                    </div>
                  <% "timeseries" -> %>
                    <.timeseries_chart
                      id={"chart-#{panel["id"]}"}
                      panel={panel}
                      rows={panel_rows(panel, @datasets, @dashboard)}
                    />
                  <% "sunburst" -> %>
                    <.sunburst_chart
                      id={"chart-#{panel["id"]}"}
                      panel={panel}
                      rows={panel_rows(panel, @datasets, @dashboard)}
                    />
                  <% "bargauge" -> %>
                    <div class="max-h-56 space-y-2 overflow-auto">
                      <div
                        :for={row <- panel_rows(panel, @datasets, @dashboard)}
                        class="grid grid-cols-[minmax(8rem,1fr)_3fr_auto] items-center gap-2 text-xs"
                      >
                        <span class="truncate text-[#cdd6f4]">{series_label(row)}</span>
                        <div class="h-3 border border-[#f9e2af]/20 bg-[#11111b]/60">
                          <div
                            class="h-full bg-gradient-to-r from-[#f9e2af] to-[#fab387]"
                            style={"width: #{bar_height(row)}%"}
                          />
                        </div>
                        <span class="font-semibold text-[#f9e2af]">{format_cell(Map.get(row, "value"))}</span>
                      </div>
                    </div>
                  <% "state-timeline" -> %>
                    <div class="max-h-56 space-y-1.5 overflow-auto">
                      <div
                        :for={row <- panel_rows(panel, @datasets, @dashboard)}
                        class="grid grid-cols-[minmax(10rem,1fr)_4rem_1fr] items-center gap-2 border border-[#b4befe]/10 bg-[#11111b]/35 px-2 py-1.5 text-xs"
                      >
                        <span class="truncate text-[#cdd6f4]">{series_label(row)}</span>
                        <span class={state_class(Map.get(row, "value"))}>{state_label(
                          Map.get(row, "value")
                        )}</span>
                        <span class="truncate text-[#9399b2]">{format_cell(Map.get(row, "time"))}</span>
                      </div>
                    </div>
                  <% _ -> %>
                    <.data_table rows={panel_rows(panel, @datasets, @dashboard)} />
                <% end %>
              <% end %>
            <% end %>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :panel, :map, required: true
  attr :rows, :list, required: true

  def timeseries_chart(assigns) do
    assigns =
      assign(assigns, :chart_json, Jason.encode!(chart_payload(assigns.rows, assigns.panel)))

    assigns = assign(assigns, :stacked, stacked_attr(assigns.panel))
    assigns = assign(assigns, :legend_position, legend_position(assigns.panel))
    assigns = assign(assigns, :height, panel_height(assigns.panel, 160))

    ~H"""
    <div
      id={@id}
      phx-hook="D3Timeseries"
      phx-update="ignore"
      data-chart={@chart_json}
      data-height={@height}
      data-stacked={@stacked}
      data-legend-position={@legend_position}
      class="relative min-h-40 border border-[#89dceb]/20 bg-[#11111b]/45 p-2"
    />
    """
  end

  attr :id, :string, required: true
  attr :panel, :map, required: true
  attr :rows, :list, required: true

  def sunburst_chart(assigns) do
    assigns =
      assign(assigns, :chart_json, Jason.encode!(sunburst_payload(assigns.rows, assigns.panel)))

    assigns = assign(assigns, :height, panel_height(assigns.panel, 160))

    ~H"""
    <div
      id={@id}
      phx-hook="D3Sunburst"
      phx-update="ignore"
      data-chart={@chart_json}
      data-height={@height}
      class="relative min-h-40 border border-[#cba6f7]/20 bg-[#11111b]/45 p-2"
    />
    """
  end

  attr :rows, :list, required: true

  def data_table(assigns) do
    assigns = assign(assigns, :columns, columns(assigns.rows))

    ~H"""
    <div class="max-h-64 overflow-auto border border-[#b4befe]/15">
      <table class="min-w-full divide-y divide-[#45475a]/70 text-xs">
        <thead class="bg-[#11111b]/60">
          <tr>
            <th
              :for={column <- @columns}
              class="px-2 py-1.5 text-left text-[0.65rem] font-semibold uppercase tracking-[0.14em] text-[#89dceb]"
            >
              {column}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-[#45475a]/50">
          <tr :for={row <- @rows} class="hover:bg-[#313244]/45">
            <td :for={column <- @columns} class="px-2 py-1.5 text-[#cdd6f4]">
              {format_cell(Map.get(row, column))}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@rows == []} class="p-3 text-xs text-[#a6adc8]">No rows returned.</div>
    </div>
    """
  end

  defp columns([]), do: []
  defp columns([row | _]), do: row |> Map.drop(["legend_format"]) |> Map.keys()

  defp panel_rows(%{"datasets" => panel_datasets}, datasets, dashboard)
       when is_list(panel_datasets) do
    Enum.flat_map(panel_datasets, fn panel_dataset ->
      dataset = panel_dataset_name(panel_dataset)

      datasets
      |> Map.get(dataset, [])
      |> Enum.map(&put_dataset_metadata(&1, dataset, panel_dataset, dashboard))
    end)
  end

  defp panel_rows(%{"dataset" => dataset}, datasets, dashboard) do
    datasets
    |> Map.get(dataset, [])
    |> Enum.map(&put_dataset_metadata(&1, dataset, dataset, dashboard))
  end

  defp panel_rows(_panel, _datasets, _dashboard), do: []

  defp collapsed_sections(dashboard) do
    dashboard
    |> Map.get("panels", [])
    |> Enum.filter(&(Map.get(&1, "type") == "row" and Map.get(&1, "collapsed") == true))
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp dashboard_breadcrumbs(dashboard) do
    folder = get_in(dashboard, ["metadata", "folder"])
    title = get_in(dashboard, ["metadata", "title"]) || get_in(dashboard, ["metadata", "name"])

    folder_parts =
      case folder do
        value when is_binary(value) and value not in ["", "root"] ->
          String.split(value, "/", trim: true)

        _folder ->
          []
      end

    folder_parts ++ [title]
  end

  defp visible_panels(dashboard, collapsed_sections) do
    {panels, _collapsed?} =
      dashboard
      |> Map.get("panels", [])
      |> Enum.reduce({[], false}, fn panel, {visible, current_section_collapsed?} ->
        if Map.get(panel, "type") == "row" do
          collapsed? = section_collapsed?(panel, collapsed_sections)
          {[panel | visible], collapsed?}
        else
          if current_section_collapsed? do
            {visible, current_section_collapsed?}
          else
            {[panel | visible], current_section_collapsed?}
          end
        end
      end)

    Enum.reverse(panels)
  end

  defp section_collapsed?(%{"type" => "row", "id" => id}, collapsed_sections),
    do: MapSet.member?(collapsed_sections, id)

  defp section_collapsed?(_panel, _collapsed_sections), do: false

  defp section_collapsed_attr(%{"type" => "row"} = panel, collapsed_sections),
    do: section_collapsed?(panel, collapsed_sections) |> to_string()

  defp section_collapsed_attr(_panel, _collapsed_sections), do: nil

  defp stacked_attr(%{"stacked" => true}), do: "true"
  defp stacked_attr(_panel), do: "false"

  defp dashboard_columns(dashboard) do
    dashboard
    |> get_in(["layout", "columns"])
    |> bounded_integer(3, 1, 16)
  end

  defp panel_width(%{"type" => "row"}, dashboard), do: dashboard_columns(dashboard)

  defp panel_width(panel, dashboard) do
    columns = dashboard_columns(dashboard)

    case get_in(panel, ["layout", "width"]) do
      "full" -> columns
      width -> bounded_integer(width, 1, 1, columns)
    end
  end

  defp panel_height(panel, default) do
    panel
    |> get_in(["layout", "height"])
    |> bounded_integer(default, 120, 800)
  end

  defp bounded_integer(value, _default, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp bounded_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, default, min, max)
      _invalid -> default
    end
  end

  defp bounded_integer(_value, default, _min, _max), do: default

  defp legend_position(%{"legend" => %{"position" => position}})
       when position in ["top", "bottom", "left", "right"],
       do: position

  defp legend_position(_panel), do: "bottom"

  defp panel_title(panel, dashboard, variable_values, datasources) do
    panel
    |> Map.get("title", Map.get(panel, "id", "Panel"))
    |> interpolate_panel_text(dashboard, variable_values, datasources)
  end

  defp panel_description(%{"description" => description}, dashboard, variable_values, datasources)
       when is_binary(description) and description != "" do
    interpolate_panel_text(description, dashboard, variable_values, datasources)
  end

  defp panel_description(_panel, _dashboard, _variable_values, _datasources), do: nil

  defp interpolate_panel_text(value, dashboard, variable_values, datasources)
       when is_binary(value) do
    dashboard
    |> Map.get("variables", %{})
    |> Variables.context(variable_values, datasources)
    |> then(&Variables.interpolate(value, &1))
  end

  defp interpolate_panel_text(value, _dashboard, _variable_values, _datasources), do: value

  defp panel_loading?(%{"type" => "row"}, _datasets, _loading?, _loading_datasets), do: false

  defp panel_loading?(panel, _datasets, true, %MapSet{} = loading_datasets) do
    if MapSet.size(loading_datasets) > 0 do
      panel
      |> panel_dataset_names()
      |> Enum.any?(&MapSet.member?(loading_datasets, &1))
    else
      false
    end
  end

  defp panel_loading?(%{"datasets" => panel_datasets}, datasets, true, _loading_datasets)
       when is_list(panel_datasets),
       do: Enum.any?(panel_datasets, &(not Map.has_key?(datasets, panel_dataset_name(&1))))

  defp panel_loading?(%{"dataset" => dataset}, datasets, true, _loading_datasets),
    do: not Map.has_key?(datasets, dataset)

  defp panel_loading?(_panel, _datasets, _loading?, _loading_datasets), do: false

  defp panel_error(panel, datasets, dashboard) do
    case PanelCompatibility.validate(panel, panel_rows(panel, datasets, dashboard)) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp put_dataset_metadata(row, dataset, panel_dataset, _dashboard) do
    row
    |> Map.put("dataset", dataset)
    |> maybe_put_legend_format(panel_dataset_legend_format(panel_dataset))
  end

  defp panel_dataset_name(dataset) when is_binary(dataset), do: dataset
  defp panel_dataset_name(%{"name" => dataset}) when is_binary(dataset), do: dataset
  defp panel_dataset_name(_dataset), do: nil

  defp panel_dataset_names(%{"datasets" => panel_datasets}) when is_list(panel_datasets),
    do: Enum.map(panel_datasets, &panel_dataset_name/1)

  defp panel_dataset_names(%{"dataset" => dataset}) when is_binary(dataset), do: [dataset]
  defp panel_dataset_names(_panel), do: []

  defp panel_dataset_legend_format(%{"legend" => %{"format" => format}}), do: format
  defp panel_dataset_legend_format(_dataset), do: nil

  defp maybe_put_legend_format(row, format) when is_binary(format) and format != "",
    do: Map.put(row, "legend_format", format)

  defp maybe_put_legend_format(row, _format), do: row

  defp format_cell(value) when is_binary(value), do: value
  defp format_cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_cell(value), do: inspect(value)

  defp series_label(row) do
    row
    |> Map.drop(["time", "value", "raw_value", "legend_format"])
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
    |> case do
      "" -> "series"
      label -> label
    end
  end

  defp state_label(value) when value in [0, 0.0], do: "Closed"
  defp state_label(value) when value in [1, 1.0], do: "Half Open"
  defp state_label(value) when value in [2, 2.0], do: "Open"
  defp state_label(value), do: format_cell(value)

  defp state_class(value) when value in [0, 0.0],
    do:
      "border border-[#a6e3a1]/20 bg-[#a6e3a1]/10 px-2 py-1 text-xs font-semibold text-[#a6e3a1]"

  defp state_class(value) when value in [1, 1.0],
    do:
      "border border-[#fab387]/20 bg-[#fab387]/10 px-2 py-1 text-xs font-semibold text-[#fab387]"

  defp state_class(value) when value in [2, 2.0],
    do:
      "border border-[#f38ba8]/20 bg-[#f38ba8]/10 px-2 py-1 text-xs font-semibold text-[#f38ba8]"

  defp state_class(_value), do: "mocha-chip px-2 py-1 text-xs font-semibold"

  defp chart_payload(rows, panel) do
    points =
      Enum.filter(rows, &(is_number(Map.get(&1, "time")) and is_number(Map.get(&1, "value"))))

    series =
      points
      |> group_series(panel)
      |> Enum.map(fn {label, series_rows} ->
        %{
          label: label,
          points:
            series_rows
            |> Enum.sort_by(& &1["time"])
            |> Enum.map(&[&1["time"], &1["value"]])
        }
      end)

    %{series: series}
  end

  defp sunburst_payload(rows, panel) do
    levels = sunburst_levels(rows, panel)

    root =
      Enum.reduce(rows, %{"name" => "root", "children" => %{}}, fn row, root ->
        value = numeric_value(Map.get(row, "value"))
        path = Enum.map(levels, &to_string(Map.get(row, &1, "unknown")))
        put_sunburst_value(root, path, value)
      end)

    %{root: finalize_sunburst_node(root), levels: levels}
  end

  defp sunburst_levels(_rows, %{"levels" => levels}) when is_list(levels), do: levels

  defp sunburst_levels([], _panel), do: []

  defp sunburst_levels([row | _rows], _panel) do
    row
    |> Map.drop(["time", "value", "raw_value", "dataset", "legend_format"])
    |> Map.keys()
    |> Enum.sort()
  end

  defp put_sunburst_value(node, [], value), do: Map.update(node, "value", value, &(&1 + value))

  defp put_sunburst_value(node, [name | rest], value) do
    children = Map.get(node, "children", %{})
    child = Map.get(children, name, %{"name" => name, "children" => %{}})
    child = put_sunburst_value(child, rest, value)
    Map.put(node, "children", Map.put(children, name, child))
  end

  defp finalize_sunburst_node(%{"children" => children} = node) when map_size(children) > 0 do
    children = children |> Map.values() |> Enum.map(&finalize_sunburst_node/1)

    node
    |> Map.put("children", children)
    |> Map.put("value", Enum.reduce(children, 0, &(&2 + Map.get(&1, "value", 0))))
  end

  defp finalize_sunburst_node(node), do: Map.delete(node, "children")

  defp numeric_value(value) when is_number(value), do: max(value, 0)
  defp numeric_value(_value), do: 0

  defp group_series(points, panel) do
    {order, groups} =
      Enum.reduce(points, {[], %{}}, fn row, {order, groups} ->
        label = series_label(row, panel)

        order = if Map.has_key?(groups, label), do: order, else: [label | order]
        groups = Map.update(groups, label, [row], &[row | &1])

        {order, groups}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn label -> {label, groups[label] |> Enum.reverse()} end)
  end

  defp series_label(row, _panel) do
    case Map.get(row, "legend_format") do
      format when is_binary(format) and format != "" -> render_legend_format(format, row)
      _format -> series_label(row)
    end
  end

  defp render_legend_format(format, row) do
    Regex.replace(~r/\{\{\s*([^}\s]+)\s*\}\}/, format, fn _match, key ->
      row
      |> Map.get(key, "")
      |> to_string()
    end)
  end

  defp bar_height(row) do
    value = Map.get(row, "value", 1)
    value = if is_number(value), do: value, else: 1
    min(max(round(value / 2), 8), 100)
  end
end
