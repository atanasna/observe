defmodule Observe.QueryGraphTest do
  use ExUnit.Case, async: true

  alias Observe.Provisioning
  alias Observe.QueryGraph

  test "loads datasources and dashboards recursively with folder metadata" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    assert get_in(datasources, ["eu-charge", "_meta", "folder"]) == "real"
    assert get_in(queries, ["queue_size", "_meta", "folder"]) == "applications/queues"

    assert get_in(processors, ["queue_jobs_et", "_meta", "folder"]) ==
             "applications/queues"

    assert get_in(dashboards, ["laravel", "_meta", "folder"]) == "Apps/Ampeco"
  end

  test "loads panel dataset legend formats for panel display" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    refute get_in(dashboards, ["queue", "datasets", "queue_default_pending", "label"])

    panel =
      dashboards
      |> get_in(["queue", "panels"])
      |> Enum.find(&(Map.get(&1, "id") == "pending"))

    assert get_in(panel, ["datasets", Access.at(1), "legend", "format"]) == "Default"
    assert get_in(panel, ["datasets", Access.at(2), "legend", "format"]) == "Low"
  end

  test "infers dashboard query refs from direct dataset queries" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    assert get_in(dashboards, ["queue", "queryRefs"]) == []
    assert get_in(dashboards, ["queue", "queries", "queue_size"])
    assert get_in(dashboards, ["queue", "queries", "queue_jobs_et"])

    assert get_in(dashboards, [
             "queue",
             "plan",
             :queries,
             "queue_default_jobs_et__queue_jobs_et",
             "query_ref"
           ]) ==
             "queue_jobs_et"

    assert get_in(dashboards, ["queue", "plan", :queries, "queue_default_jobs_et", "from"]) ==
             "queue_default_jobs_et__queue_jobs_et"
  end

  test "loads panel legend format for visualization-specific series names" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    panel =
      dashboards
      |> get_in(["queue", "panels"])
      |> Enum.find(&(Map.get(&1, "id") == "execution-time-default"))

    assert get_in(panel, ["legend", "format"]) == nil

    assert get_in(panel, ["datasets", Access.at(0), "legend", "format"]) ==
             "{{tenant}} - {{exported_job}}"
  end

  test "queue tenant variable is scoped by selected deployment" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    assert get_in(dashboards, ["queue", "variables", "tenant", "metric"]) ==
             ~s(app_queue_job_count{deployment="${vars.deployment}"})

    assert get_in(dashboards, ["queue", "variables", "tenant", "metric_label"]) == "tenant"
    assert get_in(dashboards, ["queue", "variables", "tenant", "include_all"]) == true
  end

  test "dashboard variables preserve yaml definition order" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)

    assert dashboards
           |> get_in(["queue", "variables"])
           |> Observe.Variables.ordered()
           |> Enum.map(fn {name, _spec} -> name end) == [
             "source",
             "deployment",
             "priority",
             "tenant",
             "job"
           ]
  end

  test "skips invalid dashboards instead of failing the full dashboard load" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, processors} = Provisioning.load_processors()

    assert {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, processors)
    assert Map.has_key?(dashboards, "laravel")
    refute Map.has_key?(dashboards, "error-explorer")
  end

  test "expands dashboard datasets from query templates with inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-charge"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{
            "datasource" => %{},
            "group_by" => %{"default" => "instance"}
          },
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "avg(rate(cpu[5m])) by (${inputs.group_by})"}
        }
      },
      "processors" => %{
        "node_cpu" => %{
          "source" => "query",
          "query" => %{"name" => "cpu_load", "inputs" => %{"datasource" => "prometheus"}}
        },
        "hot_nodes" => %{
          "source" => "processor",
          "processor" => %{"name" => "node_cpu"},
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 75}}]
        }
      },
      "datasets" => %{"hot_nodes" => %{"processor" => "hot_nodes"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "hot_nodes"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-charge" => %{}})

    assert plan.queries["hot_nodes__node_cpu"]["query_ref"] == "cpu_load"
    assert plan.queries["hot_nodes__node_cpu"]["datasource"] == "prometheus"
    assert get_in(plan.queries, ["hot_nodes__node_cpu", "request", "query"]) =~ "by (instance)"
    assert plan.queries["hot_nodes"]["from"] == "hot_nodes__node_cpu"
  end

  test "expands processor inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "queue" => %{
          "inputs" => %{"deployment" => %{}},
          "datasource" => "prometheus",
          "request" => %{"query" => "queue{deployment=\"${inputs.deployment}\"}"}
        }
      },
      "processors" => %{
        "queue_default" => %{
          "inputs" => %{"deployment" => %{}},
          "source" => "query",
          "query" => %{"name" => "queue", "inputs" => %{"deployment" => "${inputs.deployment}"}}
        }
      },
      "datasets" => %{
        "queue_default" => %{
          "processor" => "queue_default",
          "inputs" => %{"deployment" => "prod"}
        }
      },
      "panels" => [%{"id" => "queue", "type" => "table", "dataset" => "queue_default"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert get_in(plan.queries, ["queue_default", "inputs", "deployment"]) == "prod"

    assert get_in(plan.queries, ["queue_default", "request", "query"]) ==
             "queue{deployment=\"prod\"}"
  end

  test "expands query processors with transforms through an internal source node" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "execution_time" => %{"datasource" => "prometheus", "request" => %{"query" => "rate"}}
      },
      "processors" => %{
        "execution_time_seconds" => %{
          "query" => "execution_time",
          "transform" => [%{"math" => %{"field" => "value", "divide" => 1000}}]
        }
      },
      "datasets" => %{"execution_time_seconds" => %{"processor" => "execution_time_seconds"}},
      "panels" => [
        %{"id" => "execution-time", "type" => "table", "dataset" => "execution_time_seconds"}
      ]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert plan.queries["execution_time_seconds__execution_time"]["query_ref"] == "execution_time"

    assert plan.queries["execution_time_seconds"]["from"] ==
             "execution_time_seconds__execution_time"
  end

  test "expands direct query datasets" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "queue" => %{
          "inputs" => %{"deployment" => %{}, "state" => %{}},
          "datasource" => "prometheus",
          "request" => %{
            "query" => "queue{deployment=\"${inputs.deployment}\",state=\"${inputs.state}\"}"
          }
        }
      },
      "datasets" => %{
        "queue_pending" => %{
          "query" => "queue",
          "inputs" => %{"deployment" => "prod", "state" => "pending"}
        }
      },
      "panels" => [%{"id" => "queue", "type" => "table", "dataset" => "queue_pending"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert get_in(plan.queries, ["queue_pending", "query_ref"]) == "queue"
    assert get_in(plan.queries, ["queue_pending", "inputs", "deployment"]) == "prod"

    assert get_in(plan.queries, ["queue_pending", "request", "query"]) ==
             "queue{deployment=\"prod\",state=\"pending\"}"
  end

  test "rejects datasets that define both query and processor" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}}
      },
      "processors" => %{"cpu" => %{"query" => "cpu"}},
      "datasets" => %{"cpu" => %{"query" => "cpu", "processor" => "cpu"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "cannot define both query and processor"
  end

  test "rejects direct query datasets with normalization config" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}}
      },
      "datasets" => %{"cpu" => %{"query" => "cpu", "no_value" => 0}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "cannot define normalization without a processor"
  end

  test "rejects derived query templates used as datasets" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}},
        "hot_nodes" => %{"from" => "cpu_load", "transform" => []}
      },
      "processors" => %{"hot_nodes" => %{"query" => "hot_nodes"}},
      "datasets" => %{"hot_nodes" => %{"processor" => "hot_nodes"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "hot_nodes"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "references derived query hot_nodes"
  end

  test "requires query inputs for dataset expansion" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{"datasource" => %{}},
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "up"}
        }
      },
      "datasets" => %{"cpu" => %{"query" => "cpu_load"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "missing required input datasource"
  end

  test "allows explicitly optional query inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "metric" => %{
          "inputs" => %{"filter" => %{"required" => false}},
          "datasource" => "prometheus",
          "request" => %{"query" => "metric{filter=\"${inputs.filter}\"}"}
        }
      },
      "datasets" => %{"metric" => %{"query" => "metric"}},
      "panels" => [%{"id" => "metric", "type" => "table", "dataset" => "metric"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert get_in(plan.queries, ["metric", "request", "query"]) == "metric{filter=\"\"}"
  end

  test "rejects unknown query inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{"datasource" => %{}},
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "up"}
        }
      },
      "processors" => %{
        "cpu" => %{
          "source" => "query",
          "query" => %{
            "name" => "cpu_load",
            "inputs" => %{"datasource" => "prometheus", "extra" => "unused"}
          }
        }
      },
      "datasets" => %{"cpu" => %{"processor" => "cpu"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "query cpu_load received unknown input extra"
  end

  test "rejects unknown processor inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{"datasource" => %{}},
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "up"}
        }
      },
      "processors" => %{
        "cpu" => %{
          "inputs" => %{"datasource" => %{}},
          "source" => "query",
          "query" => %{
            "name" => "cpu_load",
            "inputs" => %{"datasource" => "${inputs.datasource}"}
          }
        }
      },
      "datasets" => %{
        "cpu" => %{
          "processor" => "cpu",
          "inputs" => %{"datasource" => "prometheus", "extra" => "unused"}
        }
      },
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "processor cpu received unknown input extra"
  end

  test "maps query inputs from dashboard variable formats" do
    dashboard = %{
      "variables" => %{
        "data" => %{
          "type" => "enum",
          "values" => ["eu-charge", "us-charge"],
          "match" => "/(eu|us)-charge/",
          "label" => "$1-ds",
          "formats" => %{"check" => "$1-ds-check", "next" => "$1-ds-next"}
        }
      },
      "datasources" => %{"prometheus" => %{"ref" => "eu-charge"}},
      "queries" => %{
        "metric" => %{
          "inputs" => %{"target" => %{}},
          "datasource" => "prometheus",
          "request" => %{"query" => "metric{target=\"${inputs.target}\"}"}
        }
      },
      "datasets" => %{
        "metric_check" => %{
          "query" => %{
            "name" => "metric",
            "inputs" => %{"target" => "${vars.data.formats.check}"}
          }
        }
      },
      "panels" => [%{"id" => "metric", "type" => "table", "dataset" => "metric_check"}]
    }

    assert {:ok, plan} =
             QueryGraph.plan(dashboard, %{"eu-charge" => %{}}, %{"data" => "us-charge"})

    assert get_in(plan.queries, ["metric_check", "inputs", "target"]) == "us-ds-check"

    assert get_in(plan.queries, ["metric_check", "request", "query"]) ==
             "metric{target=\"us-ds-check\"}"
  end

  test "allows panels to reference multiple datasets" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "default_pending" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}},
        "low_pending" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}}
      },
      "panels" => [
        %{
          "id" => "queue",
          "type" => "table",
          "datasets" => ["default_pending", "low_pending"]
        }
      ]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert plan.query_order == ["default_pending", "low_pending"]
  end
end
