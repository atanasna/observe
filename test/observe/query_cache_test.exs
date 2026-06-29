defmodule Observe.QueryCacheTest do
  use ExUnit.Case, async: true

  alias Observe.QueryCache

  test "fetches only the suffix when a requested range expands forward" do
    cache = start_cache!()
    parent = self()
    key = {:query, "requests"}

    fetch = fn gap ->
      send(parent, {:gap, gap})
      rows_for(gap)
    end

    assert {:ok, rows} = QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fetch)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:gap, %{from: 0, to: 120, step: 60}}

    assert {:ok, rows} = QueryCache.fetch_range(cache, key, %{from: 0, to: 300, step: 60}, fetch)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    assert_receive {:gap, %{from: 180, to: 300, step: 60}}
    refute_receive {:gap, _gap}
  end

  test "shrinking a covered range does not fetch" do
    cache = start_cache!()
    parent = self()
    key = {:query, "latency"}

    fetch = fn gap ->
      send(parent, {:gap, gap})
      rows_for(gap)
    end

    assert {:ok, _rows} = QueryCache.fetch_range(cache, key, %{from: 0, to: 300, step: 60}, fetch)
    assert_receive {:gap, %{from: 0, to: 300, step: 60}}

    assert {:ok, rows} = QueryCache.fetch_range(cache, key, %{from: 60, to: 180, step: 60}, fetch)
    assert Enum.map(rows, & &1["time"]) == [60, 120, 180]
    refute_receive {:gap, _gap}
  end

  test "fetches prefix and suffix gaps around a cached middle range" do
    cache = start_cache!()
    parent = self()
    key = {:query, "cpu"}

    fetch = fn gap ->
      send(parent, {:gap, gap})
      rows_for(gap)
    end

    assert {:ok, _rows} =
             QueryCache.fetch_range(cache, key, %{from: 120, to: 240, step: 60}, fetch)

    assert_receive {:gap, %{from: 120, to: 240, step: 60}}

    assert {:ok, rows} = QueryCache.fetch_range(cache, key, %{from: 0, to: 360, step: 60}, fetch)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300, 360]
    assert_receive {:gap, %{from: 0, to: 60, step: 60}}
    assert_receive {:gap, %{from: 300, to: 360, step: 60}}
    refute_receive {:gap, _gap}
  end

  test "deduplicates concurrent identical cache misses" do
    cache = start_cache!()
    parent = self()
    key = {:query, "shared"}

    fetch = fn gap ->
      send(parent, {:gap_started, gap, self()})

      receive do
        :release -> rows_for(gap)
      end
    end

    caller_1 =
      Task.async(fn ->
        QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fetch)
      end)

    caller_2 =
      Task.async(fn ->
        QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fetch)
      end)

    assert_receive {:gap_started, %{from: 0, to: 120, step: 60}, fetch_pid}
    refute_receive {:gap_started, _gap, _pid}, 50

    send(fetch_pid, :release)

    assert {:ok, rows_1} = Task.await(caller_1)
    assert {:ok, rows_2} = Task.await(caller_2)
    assert Enum.map(rows_1, & &1["time"]) == [0, 60, 120]
    assert rows_1 == rows_2
  end

  test "does not mark empty responses as covered" do
    cache = start_cache!()
    parent = self()
    key = {:query, "sparse"}

    assert {:ok, []} =
             QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fn gap ->
               send(parent, {:gap, gap})
               []
             end)

    assert_receive {:gap, %{from: 0, to: 120, step: 60}}

    assert {:ok, rows} =
             QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fn gap ->
               send(parent, {:gap, gap})
               rows_for(gap)
             end)

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:gap, %{from: 0, to: 120, step: 60}}
  end

  test "reports cache stats" do
    cache = start_cache!()
    key = {:query, "stats"}

    assert %{entries: 0, intervals: 0, rows: 0} = QueryCache.stats(cache)

    assert {:ok, _rows} =
             QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, &rows_for/1)

    assert %{entries: 1, intervals: 1, rows: 3} = QueryCache.stats(cache)
  end

  test "supports production cache keys that contain maps" do
    cache = start_cache!()

    key = {:prometheus_range, 123, %{"query" => "topk(20, rate(metric[2m]))", "range" => true}}

    assert {:ok, _rows} =
             QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, &rows_for/1)

    assert {:ok, rows} =
             QueryCache.fetch_range(cache, key, %{from: 0, to: 120, step: 60}, fn _gap ->
               flunk("expected cache hit")
             end)

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
  end

  defp start_cache! do
    suffix = System.unique_integer([:positive])
    task_supervisor = Module.concat(__MODULE__, "TaskSupervisor#{suffix}")
    cache = Module.concat(__MODULE__, "Cache#{suffix}")

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {QueryCache, name: cache, task_supervisor: task_supervisor, cleanup?: false}
    )
  end

  defp rows_for(%{from: from, to: to, step: step}) do
    Enum.map(from..to//step, fn time ->
      %{"series" => "a", "time" => time, "value" => time}
    end)
  end
end
