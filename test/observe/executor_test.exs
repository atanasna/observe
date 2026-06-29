defmodule Observe.ExecutorTest do
  use ExUnit.Case, async: true

  alias Observe.Executor

  test "streams each dataset as soon as it is executed" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "bravo" => %{"datasource" => "prometheus", "request" => %{"query" => "bravo"}}
      },
      "panels" => []
    }

    assert :ok =
             Executor.run_stream(
               dashboard,
               %{},
               %{datasources: %{"fake-prometheus" => %{"type" => "prometheus"}}},
               &send(self(), {:stream_event, &1})
             )

    events = stream_events([])

    assert [{:plan, _plan} | _events] = events
    assert :complete = List.last(events)

    dataset_names =
      events
      |> Enum.filter(&match?({:dataset, _name, _rows}, &1))
      |> Enum.map(fn {:dataset, name, rows} ->
        assert rows != []
        name
      end)

    assert Enum.sort(dataset_names) == ["alpha", "bravo"]
  end

  test "runs independent source queries in parallel" do
    parent = self()

    task =
      Task.async(fn ->
        Executor.run_stream(
          source_dashboard(),
          %{},
          %{
            datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
            max_concurrency: 2,
            source_dataset: fn name, _query ->
              send(parent, {:query_started, name, self()})

              receive do
                {:release_query, ^name} -> [%{"value" => name}]
              end
            end
          },
          &send(parent, {:stream_event, &1})
        )
      end)

    assert_receive {:query_started, "alpha", alpha_pid}
    assert_receive {:query_started, "bravo", bravo_pid}

    send(alpha_pid, {:release_query, "alpha"})
    send(bravo_pid, {:release_query, "bravo"})

    assert :ok = Task.await(task)
  end

  test "runs only requested source nodes" do
    assert {:ok, %{datasets: datasets}} =
             Executor.run(source_dashboard(), %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               only: MapSet.new(["alpha"]),
               source_dataset: fn name, _query -> [%{"value" => name}] end
             })

    assert Map.keys(datasets) == ["alpha"]
  end

  test "includes parents needed by requested derived nodes" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "high_alpha" => %{
          "from" => "alpha",
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 2}}]
        }
      },
      "panels" => []
    }

    assert {:ok, %{datasets: datasets}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               only: ["high_alpha"],
               source_dataset: fn "alpha", _query -> [%{"value" => 1}, %{"value" => 2}] end
             })

    assert Map.keys(datasets) |> Enum.sort() == ["alpha", "high_alpha"]
    assert datasets["high_alpha"] == [%{"value" => 2}]
  end

  test "normalizes no-value samples from processor config" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{"datasource" => "prometheus", "request" => %{"query" => "query"}}
      },
      "processors" => %{
        "queue_execution_time" => %{"query" => "execution_time", "no_value" => 0}
      },
      "datasets" => %{"queue_execution_time" => %{"processor" => "queue_execution_time"}},
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               source_dataset: fn "queue_execution_time", _query ->
                 [
                   %{"time" => 1, "value" => "NaN"},
                   %{"time" => 2, "value" => "+Inf"},
                   %{"time" => 3, "value" => "-Inf"},
                   %{"time" => 4, "value" => nil},
                   %{"time" => 5, "value" => 12.5}
                 ]
               end
             })

    assert Enum.map(rows, & &1["value"]) == [0, 0, 0, 0, 12.5]
  end

  test "fills missing samples from processor config and query interval" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "query", "range" => true, "interval" => "1m"}
        }
      },
      "processors" => %{
        "queue_execution_time" => %{"query" => "execution_time", "fill_missing" => 0}
      },
      "datasets" => %{"queue_execution_time" => %{"processor" => "queue_execution_time"}},
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               time_range: %{from: 60, to: 180},
               source_dataset: fn "queue_execution_time", _query ->
                 [
                   %{"tenant" => "a", "time" => 60, "value" => 1},
                   %{"tenant" => "a", "time" => 180, "value" => 3},
                   %{"tenant" => "b", "time" => 120, "value" => 2}
                 ]
               end
             })

    assert rows_by_series_and_time(rows) == %{
             {"a", 60} => 1,
             {"a", 120} => 0,
             {"a", 180} => 3,
             {"b", 60} => 0,
             {"b", 120} => 2,
             {"b", 180} => 0
           }
  end

  test "applies math transforms from processor config" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{"datasource" => "prometheus", "request" => %{"query" => "query"}}
      },
      "processors" => %{
        "queue_execution_time" => %{
          "query" => "execution_time",
          "transform" => [%{"math" => %{"field" => "value", "divide" => 1000}}]
        }
      },
      "datasets" => %{"queue_execution_time" => %{"processor" => "queue_execution_time"}},
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               source_dataset: fn "queue_execution_time__execution_time", _query ->
                 [%{"time" => 1, "value" => 2500}, %{"time" => 2, "value" => "NaN"}]
               end
             })

    assert Enum.map(rows, & &1["value"]) == [2.5, "NaN"]
  end

  test "normalizes transformed query processors using source query interval" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "query", "range" => true, "interval" => "1m"}
        }
      },
      "processors" => %{
        "queue_execution_time" => %{
          "query" => "execution_time",
          "no_value" => 0,
          "fill_missing" => 0,
          "transform" => [%{"math" => %{"field" => "value", "divide" => 1000}}]
        }
      },
      "datasets" => %{"queue_execution_time" => %{"processor" => "queue_execution_time"}},
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               time_range: %{from: 60, to: 180},
               source_dataset: fn "queue_execution_time__execution_time", _query ->
                 [
                   %{"tenant" => "a", "time" => 60, "value" => 2500},
                   %{"tenant" => "a", "time" => 180, "value" => "NaN"}
                 ]
               end
             })

    assert rows_by_series_and_time(rows) == %{
             {"a", 60} => 2.5,
             {"a", 120} => 0,
             {"a", 180} => 0
           }
  end

  test "delays range requests and realigns returned timestamps" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "response_time" => %{
          "datasource" => "prometheus",
          "delay" => "1h",
          "request" => %{"query" => "lb_response_time", "range" => true, "interval" => "1m"}
        }
      },
      "panels" => []
    }

    assert {:ok, %{datasets: %{"response_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               time_range: %{from: 7_200, to: 10_800},
               source_dataset: fn "response_time", query ->
                 assert get_in(query, ["request", "start"]) == 3_600
                 assert get_in(query, ["request", "end"]) == 7_200

                 [
                   %{"time" => 3_600, "value" => 10},
                   %{"time" => 7_200, "value" => 20}
                 ]
               end
             })

    assert Enum.map(rows, & &1["time"]) == [7_200, 10_800]
  end

  test "reuses cached Prometheus range data and fetches only missing suffix" do
    cache = start_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "requests" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "requests_total", "range" => true, "interval" => "1m"}
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      query_cache: cache,
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})
        {:ok, rows_for(request["start"], request["end"], 60)}
      end
    }

    assert {:ok, %{datasets: %{"requests" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 120}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"requests" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    assert_receive {:prometheus_request, 180, 300}
    refute_receive {:prometheus_request, _start, _end}
  end

  test "cached Prometheus range data still flows through execution time processors" do
    cache = start_cache!()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "execution_time", "range" => true, "interval" => "1m"}
        }
      },
      "processors" => %{
        "queue_execution_time" => %{
          "query" => "execution_time",
          "no_value" => 0,
          "fill_missing" => 0,
          "transform" => [%{"math" => %{"field" => "value", "divide" => 1000}}]
        }
      },
      "datasets" => %{"queue_execution_time" => %{"processor" => "queue_execution_time"}},
      "panels" => []
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{
                 "fake-prometheus" => %{
                   "type" => "prometheus",
                   "mode" => "real",
                   "url" => "http://prometheus.test"
                 }
               },
               query_cache: cache,
               time_range: %{from: 60, to: 180},
               prometheus_execute: fn _datasource, request ->
                 {:ok,
                  [
                    %{
                      "tenant" => "a",
                      "exported_job" => "Job",
                      "time" => request["start"],
                      "value" => 2500
                    },
                    %{
                      "tenant" => "a",
                      "exported_job" => "Job",
                      "time" => request["end"],
                      "value" => "NaN"
                    }
                  ]}
               end
             })

    assert rows_by_job_and_time(rows) == %{
             {"Job", 60} => 2.5,
             {"Job", 120} => 0,
             {"Job", 180} => 0
           }
  end

  test "does not use raw query cache for topk Prometheus range queries" do
    cache = start_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "pressure" => %{
          "datasource" => "prometheus",
          "request" => %{
            "query" => "topk(20, rate(metric[2m]))",
            "range" => true,
            "interval" => "1m"
          }
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      query_cache: cache,
      dataset_cache: nil,
      time_range: %{from: 0, to: 120},
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})
        {:ok, rows_for(request["start"], request["end"], 60)}
      end
    }

    assert {:ok, %{datasets: %{"pressure" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"pressure" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}
    assert %{entries: 0, hits: 0, misses: 0} = Observe.QueryCache.stats(cache)

    assert {:ok, %{datasets: %{"pressure" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 180}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180]
    assert_receive {:prometheus_request, 0, 180}
  end

  test "raw topk Prometheus range queries do not get stuck empty" do
    cache = start_cache!()
    parent = self()
    counter = :counters.new(1, [])

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "pressure" => %{
          "datasource" => "prometheus",
          "request" => %{
            "query" => "topk(20, rate(metric[2m]))",
            "range" => true,
            "interval" => "1m"
          }
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      query_cache: cache,
      dataset_cache: nil,
      time_range: %{from: 0, to: 120},
      prometheus_execute: fn _datasource, request ->
        :counters.add(counter, 1, 1)
        send(parent, {:prometheus_request, request["start"], request["end"]})

        if :counters.get(counter, 1) == 1 do
          {:ok, []}
        else
          {:ok, rows_for(request["start"], request["end"], 60)}
        end
      end
    }

    assert {:ok, %{datasets: %{"pressure" => []}}} = Executor.run(dashboard, %{}, opts)
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"pressure" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"pressure" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}
  end

  test "caches final source datasets by exact range" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "requests" => %{"datasource" => "prometheus", "request" => %{"query" => "requests"}}
      },
      "panels" => []
    }

    opts = %{
      datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
      dataset_cache: cache,
      time_range: %{from: 0, to: 120},
      source_dataset: fn "requests", _query ->
        send(parent, :source_executed)
        [%{"time" => 0, "value" => 1}]
      end
    }

    assert {:ok, %{datasets: %{"requests" => [%{"value" => 1}]}}} =
             Executor.run(dashboard, %{}, opts)

    assert_receive :source_executed

    assert {:ok, %{datasets: %{"requests" => [%{"value" => 1}]}}} =
             Executor.run(dashboard, %{}, opts)

    refute_receive :source_executed
    assert %{hits: 1, misses: 1, puts: 1} = Observe.DatasetCache.stats(cache)
  end

  test "caches final derived datasets by exact range" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "source" => %{"datasource" => "prometheus", "request" => %{"query" => "source"}},
        "derived" => %{
          "from" => "source",
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 2}}]
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
      dataset_cache: cache,
      time_range: %{from: 0, to: 120},
      source_dataset: fn "source", _query ->
        send(parent, :source_executed)
        [%{"time" => 0, "value" => 1}, %{"time" => 60, "value" => 2}]
      end
    }

    assert {:ok, %{datasets: %{"derived" => [%{"value" => 2}]}}} =
             Executor.run(dashboard, %{}, opts)

    assert_receive :source_executed

    assert {:ok, %{datasets: %{"derived" => [%{"value" => 2}]}}} =
             Executor.run(dashboard, %{}, opts)

    refute_receive :source_executed
    assert %{hits: hits, misses: 2, puts: 2} = Observe.DatasetCache.stats(cache)
    assert hits >= 2
  end

  test "incrementally caches final source datasets by time range" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "requests" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "requests", "range" => true, "interval" => "1m"}
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      dataset_cache: cache,
      query_cache: nil,
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})
        {:ok, rows_for(request["start"], request["end"], 60)}
      end
    }

    assert {:ok, %{datasets: %{"requests" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 120}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"requests" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    assert_receive {:prometheus_request, 180, 300}
    refute_receive {:prometheus_request, _start, _end}
    assert %{range_hits: 0, range_misses: 2, fetched_gaps: 2} = Observe.DatasetCache.stats(cache)

    assert {:ok, %{datasets: %{"requests" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    refute_receive {:prometheus_request, _start, _end}
    assert %{range_hits: 1} = Observe.DatasetCache.stats(cache)
  end

  test "dataset range cache hits rows with float timestamps" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "requests" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "requests", "range" => true, "interval" => "1m"}
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      dataset_cache: cache,
      query_cache: nil,
      time_range: %{from: 0, to: 120},
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})

        {:ok,
         Enum.map(request["start"]..request["end"]//60, fn time ->
           %{"service" => "api", "time" => time / 1, "value" => time}
         end)}
      end
    }

    assert {:ok, %{datasets: %{"requests" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0.0, 60.0, 120.0]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"requests" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0.0, 60.0, 120.0]
    refute_receive {:prometheus_request, _start, _end}
    assert %{range_hits: 1} = Observe.DatasetCache.stats(cache)
  end

  test "incrementally caches final derived datasets by time range" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "source" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "source", "range" => true, "interval" => "1m"}
        },
        "derived" => %{
          "from" => "source",
          "transform" => [%{"math" => %{"field" => "value", "divide" => 10}}]
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      dataset_cache: cache,
      query_cache: nil,
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})
        {:ok, rows_for(request["start"], request["end"], 60)}
      end
    }

    assert {:ok, %{datasets: %{"derived" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 120}))

    assert Enum.map(rows, & &1["value"]) == [0.0, 6.0, 12.0]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"derived" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    assert Enum.map(rows, & &1["value"]) == [0.0, 6.0, 12.0, 18.0, 24.0, 30.0]
    assert_receive {:prometheus_request, 180, 300}
    refute_receive {:prometheus_request, _start, _end}
  end

  test "topk-backed final datasets use exact dataset cache" do
    cache = start_dataset_cache!()
    parent = self()

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "source" => %{
          "datasource" => "prometheus",
          "request" => %{
            "query" => "topk(20, rate(metric[2m]))",
            "range" => true,
            "interval" => "1m"
          }
        },
        "derived" => %{
          "from" => "source",
          "transform" => [%{"math" => %{"field" => "value", "divide" => 10}}]
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      dataset_cache: cache,
      query_cache: nil,
      prometheus_execute: fn _datasource, request ->
        send(parent, {:prometheus_request, request["start"], request["end"]})
        {:ok, rows_for(request["start"], request["end"], 60)}
      end
    }

    assert {:ok, %{datasets: %{"derived" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 120}))

    assert Enum.map(rows, & &1["value"]) == [0.0, 6.0, 12.0]
    assert_receive {:prometheus_request, 0, 120}

    assert {:ok, %{datasets: %{"derived" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    assert_receive {:prometheus_request, 0, 300}

    assert {:ok, %{datasets: %{"derived" => rows}}} =
             Executor.run(dashboard, %{}, Map.put(opts, :time_range, %{from: 0, to: 300}))

    assert Enum.map(rows, & &1["time"]) == [0, 60, 120, 180, 240, 300]
    refute_receive {:prometheus_request, _start, _end}
    assert %{entries: entries, hits: hits, range_entries: 0} = Observe.DatasetCache.stats(cache)
    assert entries > 0
    assert hits > 0
  end

  test "does not cache empty final datasets" do
    cache = start_dataset_cache!()
    parent = self()
    counter = :counters.new(1, [])

    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "source" => %{
          "datasource" => "prometheus",
          "request" => %{
            "query" => "topk(20, rate(metric[2m]))",
            "range" => true,
            "interval" => "1m"
          }
        }
      },
      "panels" => []
    }

    opts = %{
      datasources: %{
        "fake-prometheus" => %{
          "type" => "prometheus",
          "mode" => "real",
          "url" => "http://prometheus.test"
        }
      },
      dataset_cache: cache,
      query_cache: nil,
      time_range: %{from: 0, to: 120},
      prometheus_execute: fn _datasource, request ->
        :counters.add(counter, 1, 1)
        send(parent, {:prometheus_request, request["start"], request["end"]})

        if :counters.get(counter, 1) == 1 do
          {:ok, []}
        else
          {:ok, rows_for(request["start"], request["end"], 60)}
        end
      end
    }

    assert {:ok, %{datasets: %{"source" => []}}} = Executor.run(dashboard, %{}, opts)
    assert_receive {:prometheus_request, 0, 120}
    assert %{entries: 0} = Observe.DatasetCache.stats(cache)

    assert {:ok, %{datasets: %{"source" => rows}}} = Executor.run(dashboard, %{}, opts)
    assert Enum.map(rows, & &1["time"]) == [0, 60, 120]
    assert_receive {:prometheus_request, 0, 120}
  end

  defp source_dashboard do
    %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "bravo" => %{"datasource" => "prometheus", "request" => %{"query" => "bravo"}}
      },
      "panels" => []
    }
  end

  defp stream_events(events) do
    receive do
      {:stream_event, event} -> stream_events(events ++ [event])
    after
      0 -> events
    end
  end

  defp rows_by_series_and_time(rows) do
    Map.new(rows, fn row -> {{row["tenant"], row["time"]}, row["value"]} end)
  end

  defp rows_by_job_and_time(rows) do
    Map.new(rows, fn row -> {{row["exported_job"], row["time"]}, row["value"]} end)
  end

  defp start_cache! do
    suffix = System.unique_integer([:positive])
    task_supervisor = Module.concat(__MODULE__, "TaskSupervisor#{suffix}")
    cache = Module.concat(__MODULE__, "Cache#{suffix}")

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {Observe.QueryCache, name: cache, task_supervisor: task_supervisor, cleanup?: false}
    )
  end

  defp start_dataset_cache! do
    cache = Module.concat(__MODULE__, "DatasetCache#{System.unique_integer([:positive])}")
    start_supervised!({Observe.DatasetCache, name: cache, cleanup?: false})
  end

  defp rows_for(from, to, step) do
    Enum.map(from..to//step, fn time ->
      %{"service" => "api", "time" => time, "value" => time}
    end)
  end
end
