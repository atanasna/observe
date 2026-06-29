defmodule Observe.DatasetCache do
  @moduledoc """
  Global cache for final executor datasets.

  Exact entries cache non-time datasets. Range entries cache final time-indexed
  rows by covered interval, after source execution, normalization, and transforms.
  """

  use GenServer

  @default_ttl_ms :timer.minutes(15)
  @cleanup_ms :timer.minutes(1)
  @timeout :infinity

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def fetch(server \\ __MODULE__, key, fun) when is_function(fun, 0) do
    case lookup(server, key) do
      {:ok, rows} ->
        {:ok, rows}

      :miss ->
        rows = fun.()
        put(server, key, rows)
        {:ok, rows}
    end
  end

  def fetch_range(server \\ __MODULE__, key, %{from: from, to: to, step: step}, fetch_fun)
      when is_function(fetch_fun, 1) and is_integer(step) and step > 0 do
    range = normalize_range(from, to, step)
    GenServer.call(server, {:fetch_range, key, range, fetch_fun}, @timeout)
  end

  def lookup(server \\ __MODULE__, key) do
    GenServer.call(server, {:lookup, key})
  end

  def put(server \\ __MODULE__, key, rows) when is_list(rows) do
    GenServer.call(server, {:put, key, rows})
  end

  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    exact_table =
      :ets.new(:observe_dataset_exact_cache, [:set, :protected, read_concurrency: true])

    row_table = :ets.new(:observe_dataset_range_cache, [:set, :protected, read_concurrency: true])

    if Keyword.get(opts, :cleanup?, true) do
      Process.send_after(self(), :cleanup, @cleanup_ms)
    end

    {:ok,
     %{
       exact_table: exact_table,
       row_table: row_table,
       range_entries: %{},
       inflight: %{},
       ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
       cleanup?: Keyword.get(opts, :cleanup?, true),
       task_supervisor: Keyword.get(opts, :task_supervisor, Observe.QueryTaskSupervisor),
       counters: %{hits: 0, misses: 0, puts: 0, range_hits: 0, range_misses: 0, fetched_gaps: 0}
     }}
  end

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    case :ets.lookup(state.exact_table, key) do
      [{^key, rows, _last_accessed_at}] ->
        :ets.insert(state.exact_table, {key, rows, now_ms()})
        {:reply, {:ok, rows}, update_counter(state, :hits, 1)}

      [] ->
        {:reply, :miss, update_counter(state, :misses, 1)}
    end
  end

  def handle_call({:put, key, rows}, _from, state) do
    if cacheable_rows?(rows) do
      :ets.insert(state.exact_table, {key, rows, now_ms()})
      {:reply, :ok, update_counter(state, :puts, 1)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:fetch_range, key, range, fetch_fun}, from, state) do
    entry = Map.get(state.range_entries, key, new_range_entry())
    gaps = missing_intervals(range, entry.intervals)

    if gaps == [] do
      rows = read_range_rows(state.row_table, key, range)

      state =
        state
        |> put_in([:range_entries, key], touch(entry))
        |> update_counter(:range_hits, 1)

      {:reply, {:ok, rows}, state}
    else
      inflight_key = {key, gaps}

      case Map.get(state.inflight, inflight_key) do
        nil ->
          task =
            Task.Supervisor.async_nolink(state.task_supervisor, fn ->
              fetch_gaps(gaps, fetch_fun)
            end)

          inflight =
            Map.put(state.inflight, inflight_key, %{
              task_ref: task.ref,
              callers: [{from, range}],
              empty_before?: entry.intervals == []
            })

          state =
            state
            |> put_in([:inflight], inflight)
            |> update_counter(:range_misses, 1)
            |> update_counter(:fetched_gaps, length(gaps))

          {:noreply, state}

        %{callers: callers} = pending ->
          inflight =
            Map.put(state.inflight, inflight_key, %{pending | callers: [{from, range} | callers]})

          {:noreply, %{state | inflight: inflight}}
      end
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.exact_table)
    :ets.delete_all_objects(state.row_table)

    {:reply, :ok,
     %{
       state
       | range_entries: %{},
         inflight: %{},
         counters: %{hits: 0, misses: 0, puts: 0, range_hits: 0, range_misses: 0, fetched_gaps: 0}
     }}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      entries: :ets.info(state.exact_table, :size),
      range_entries: map_size(state.range_entries),
      rows: :ets.info(state.row_table, :size),
      inflight: map_size(state.inflight),
      hits: state.counters.hits,
      misses: state.counters.misses,
      puts: state.counters.puts,
      range_hits: state.counters.range_hits,
      range_misses: state.counters.range_misses,
      fetched_gaps: state.counters.fetched_gaps
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({ref, {:ok, fetched}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {inflight_key, pending} = inflight_by_ref(state.inflight, ref)

    state =
      if pending do
        {key, gaps} = inflight_key
        entry = Map.get(state.range_entries, key, new_range_entry())
        write_range_rows(state.row_table, key, fetched)

        entry =
          if timestamped_rows?(fetched) do
            entry
            |> merge_intervals(gaps)
            |> touch()
          else
            touch(entry)
          end

        Enum.each(pending.callers, fn {caller, requested_range} ->
          rows =
            if pending.empty_before? and gaps == [requested_range] do
              fetched
            else
              read_range_rows(state.row_table, key, requested_range)
            end

          GenServer.reply(caller, {:ok, rows})
        end)

        state
        |> put_in([:range_entries, key], entry)
        |> update_in([:inflight], &Map.delete(&1, inflight_key))
        |> update_counter(:puts, 1)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, reply_inflight_error(state, ref, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, reply_inflight_error(state, ref, reason)}
  end

  def handle_info(:cleanup, state) do
    cutoff = now_ms() - state.ttl_ms

    state.exact_table
    |> :ets.tab2list()
    |> Enum.each(fn {key, _rows, last_accessed_at} ->
      if last_accessed_at < cutoff, do: :ets.delete(state.exact_table, key)
    end)

    {expired, range_entries} =
      Enum.split_with(state.range_entries, fn {_key, entry} -> entry.last_accessed_at < cutoff end)

    Enum.each(expired, fn {key, _entry} -> delete_range_rows(state.row_table, key) end)

    if state.cleanup? do
      Process.send_after(self(), :cleanup, @cleanup_ms)
    end

    {:noreply, %{state | range_entries: Map.new(range_entries)}}
  end

  defp fetch_gaps(gaps, fetch_fun) do
    rows =
      Enum.flat_map(gaps, fn gap ->
        case fetch_fun.(gap) do
          {:ok, rows} when is_list(rows) -> rows
          rows when is_list(rows) -> rows
          {:error, reason} -> throw({:dataset_cache_error, reason})
        end
      end)

    {:ok, rows}
  catch
    {:dataset_cache_error, reason} -> {:error, reason}
  end

  defp missing_intervals(range, intervals) do
    {cursor, gaps} =
      intervals
      |> Enum.sort_by(& &1.from)
      |> Enum.reduce_while({range.from, []}, fn interval, {cursor, gaps} ->
        cond do
          cursor > range.to ->
            {:halt, {cursor, gaps}}

          interval.to < cursor ->
            {:cont, {cursor, gaps}}

          interval.from > range.to ->
            {:halt, {cursor, gaps}}

          interval.from > cursor ->
            gap = %{from: cursor, to: min(interval.from - range.step, range.to), step: range.step}
            cursor = max(cursor, interval.to + range.step)
            {:cont, {cursor, [gap | gaps]}}

          true ->
            {:cont, {max(cursor, interval.to + range.step), gaps}}
        end
      end)

    gaps =
      if cursor <= range.to,
        do: [%{from: cursor, to: range.to, step: range.step} | gaps],
        else: gaps

    gaps |> Enum.reverse() |> Enum.reject(&(&1.from > &1.to))
  end

  defp write_range_rows(table, key, rows) do
    rows
    |> Enum.filter(&(is_map(&1) and is_number(Map.get(&1, "time"))))
    |> Enum.group_by(&time_key(&1["time"]))
    |> Enum.map(fn {time, rows} -> {{key, time}, dedupe_rows(rows)} end)
    |> then(fn
      [] -> :ok
      objects -> :ets.insert(table, objects)
    end)
  end

  defp read_range_rows(table, key, range) do
    range.from..range.to//range.step
    |> Enum.flat_map(fn time ->
      case :ets.lookup(table, {key, time}) do
        [{{^key, ^time}, rows}] -> rows
        [] -> []
      end
    end)
  end

  defp delete_range_rows(table, key) do
    table
    |> :ets.match({{key, :_}, :_})
    |> Enum.each(fn [time] -> :ets.delete(table, {key, time}) end)
  end

  defp series_key(row), do: Map.drop(row, ["time", "value", "raw_value"])

  defp time_key(time) when is_float(time), do: floor(time)
  defp time_key(time), do: time

  defp dedupe_rows(rows) do
    rows
    |> Map.new(fn row -> {series_key(row), row} end)
    |> Map.values()
  end

  defp timestamped_rows?(rows) do
    Enum.any?(rows, &(is_map(&1) and is_number(Map.get(&1, "time"))))
  end

  defp cacheable_rows?(rows) do
    rows != [] and not Enum.any?(rows, &(is_map(&1) and Map.has_key?(&1, "error")))
  end

  defp merge_intervals(entry, intervals) do
    intervals =
      (entry.intervals ++ intervals)
      |> Enum.sort_by(& &1.from)
      |> Enum.reduce([], fn
        interval, [] ->
          [interval]

        interval, [current | rest] ->
          if interval.from <= current.to + current.step do
            [%{current | to: max(current.to, interval.to)} | rest]
          else
            [interval, current | rest]
          end
      end)
      |> Enum.reverse()

    %{entry | intervals: intervals}
  end

  defp inflight_by_ref(inflight, ref) do
    Enum.find(inflight, fn {_key, pending} -> pending.task_ref == ref end) || {nil, nil}
  end

  defp reply_inflight_error(state, ref, reason) do
    {inflight_key, pending} = inflight_by_ref(state.inflight, ref)

    if pending do
      Enum.each(pending.callers, fn {caller, _range} ->
        GenServer.reply(caller, {:error, reason})
      end)

      update_in(state.inflight, &Map.delete(&1, inflight_key))
    else
      state
    end
  end

  defp normalize_range(from, to, step) when is_number(from) and is_number(to) do
    low = floor(min(from, to))
    high = floor(max(from, to))
    %{from: align_down(low, step), to: align_down(high, step), step: step}
  end

  defp align_down(value, step), do: value - rem(value, step)

  defp new_range_entry, do: %{intervals: [], last_accessed_at: now_ms()}
  defp touch(entry), do: %{entry | last_accessed_at: now_ms()}
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp update_counter(state, counter, amount) do
    update_in(state.counters[counter], &((&1 || 0) + amount))
  end
end
