defmodule Observe.QueryGraphTest do
  use ExUnit.Case, async: true

  alias Observe.Provisioning
  alias Observe.QueryGraph

  test "loads datasources and dashboards recursively with folder metadata" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

    assert get_in(datasources, ["eu-charge", "_meta", "folder"]) == "real"
    assert get_in(queries, ["queue_size", "_meta", "folder"]) == "applications/queues"
    assert get_in(datasets, ["queue_default_pending", "_meta", "folder"]) == "applications/queues"
    assert get_in(dashboards, ["laravel", "_meta", "folder"]) == "Apps/Ampeco"
  end

  test "loads panel dataset legend formats for panel display" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

    refute get_in(dashboards, ["queue", "datasets", "queue_default_pending", "label"])

    panel =
      dashboards
      |> get_in(["queue", "panels"])
      |> Enum.find(&(Map.get(&1, "id") == "pending"))

    assert get_in(panel, ["datasets", Access.at(1), "legend", "format"]) == "Default"
    assert get_in(panel, ["datasets", Access.at(2), "legend", "format"]) == "Low"
  end

  test "infers dashboard query refs from dataset sources" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

    assert get_in(dashboards, ["queue", "queryRefs"]) == []
    assert get_in(dashboards, ["queue", "queries", "queue_size"])
    assert get_in(dashboards, ["queue", "queries", "queue_jobs_et"])

    assert get_in(dashboards, ["queue", "plan", :queries, "queue_default_jobs_et", "query_ref"]) ==
             "queue_jobs_et"
  end

  test "loads panel legend format for visualization-specific series names" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

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
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

    assert get_in(dashboards, ["queue", "variables", "tenant", "metric"]) ==
             ~s(app_queue_job_count{deployment="${vars.deployment}"})

    assert get_in(dashboards, ["queue", "variables", "tenant", "metric_label"]) == "tenant"
    assert get_in(dashboards, ["queue", "variables", "tenant", "include_all"]) == true
  end

  test "dashboard variables preserve yaml definition order" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, datasets} = Provisioning.load_datasets()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)

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
    {:ok, datasets} = Provisioning.load_datasets()

    assert {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries, datasets)
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
      "datasets" => %{
        "node_cpu" => %{
          "source" => "query",
          "query" => %{"name" => "cpu_load", "inputs" => %{"datasource" => "prometheus"}}
        },
        "hot_nodes" => %{
          "source" => "dataset",
          "dataset" => %{"name" => "node_cpu"},
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 75}}]
        }
      },
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "hot_nodes"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-charge" => %{}})

    assert plan.queries["node_cpu"]["query_ref"] == "cpu_load"
    assert plan.queries["node_cpu"]["datasource"] == "prometheus"
    assert get_in(plan.queries, ["node_cpu", "request", "query"]) =~ "by (instance)"
    assert plan.queries["hot_nodes"]["from"] == "node_cpu"
  end

  test "expands provisioned dataset template inputs" do
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
      "datasets" => %{
        "queue_default" => %{
          "_input_schema" => %{"deployment" => %{}},
          "inputs" => %{"deployment" => "prod"},
          "source" => "query",
          "query" => %{"name" => "queue", "inputs" => %{"deployment" => "${inputs.deployment}"}}
        }
      },
      "panels" => [%{"id" => "queue", "type" => "table", "dataset" => "queue_default"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert get_in(plan.queries, ["queue_default", "inputs", "deployment"]) == "prod"

    assert get_in(plan.queries, ["queue_default", "request", "query"]) ==
             "queue{deployment=\"prod\"}"
  end

  test "rejects derived query templates used as datasets" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{"datasource" => "prometheus", "request" => %{"query" => "up"}},
        "hot_nodes" => %{"from" => "cpu_load", "transform" => []}
      },
      "datasets" => %{"hot_nodes" => %{"query" => "hot_nodes"}},
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
      "datasets" => %{
        "metric" => %{"source" => "query", "query" => %{"name" => "metric"}}
      },
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
      "datasets" => %{
        "cpu" => %{
          "source" => "query",
          "query" => %{
            "name" => "cpu_load",
            "inputs" => %{"datasource" => "prometheus", "extra" => "unused"}
          }
        }
      },
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "query cpu_load received unknown input extra"
  end

  test "rejects unknown dataset template inputs" do
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
      "datasets" => %{
        "cpu" => %{
          "_input_schema" => %{"datasource" => %{}},
          "inputs" => %{"datasource" => "prometheus", "extra" => "unused"},
          "source" => "query",
          "query" => %{
            "name" => "cpu_load",
            "inputs" => %{"datasource" => "${inputs.datasource}"}
          }
        }
      },
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "dataset cpu received unknown input extra"
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
          "query" => "metric",
          "inputs" => %{"target" => "${vars.data.formats.check}"}
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
