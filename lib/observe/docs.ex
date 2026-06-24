defmodule Observe.Docs do
  @moduledoc """
  Structured documentation content for the in-app documentation site.
  """

  def pages do
    [
      overview(),
      yaml_reference(),
      datasource_reference(),
      ui_reference(),
      variable_reference(),
      query_reference(),
      transform_reference(),
      panel_reference(),
      runtime_reference(),
      examples()
    ]
  end

  def get(slug), do: Enum.find(pages(), &(&1.slug == slug))
  def first_slug, do: hd(pages()).slug

  defp overview do
    %{
      slug: "overview",
      title: "Overview",
      summary: "What Observe is and how the model differs from Grafana.",
      sections: [
        text(
          "Observe is a YAML-provisioned observability dashboard system built around reusable query graphs. The key design rule is simple: panels consume datasets, while top-level queries produce datasets."
        ),
        bullets("Core ideas", [
          "Queries are named top-level dashboard entities.",
          "A source query fetches data from a datasource alias.",
          "A derived query transforms the result of another query.",
          "Panels reference datasets by name and never own source queries.",
          "Variables can resolve multiple datasource aliases from one selection."
        ]),
        code("Minimal dashboard", """
        apiVersion: observe/v1
        kind: Dashboard

        metadata:
          name: service-overview
          title: Service Overview

        variables:
          region:
            type: enum
            values: [eu, sg, uk]
            default: eu

        datasources:
          prometheus:
            ref: ${vars.region}-p

        queries:
          request_rate:
            datasource: prometheus
            request:
              query: sum(rate(http_requests_total[5m])) by (service)

        panels:
          - id: request-rate
            title: Request Rate
            type: timeseries
            dataset: request_rate
        """),
        callout(
          "Current implementation",
          "Prometheus can execute real HTTP API queries when a datasource uses mode: real. CloudWatch and OpenSearch are still stubbed. YAML loading, variable resolution, graph planning, transforms, and rendering are real."
        )
      ]
    }
  end

  defp yaml_reference do
    %{
      slug: "yaml-reference",
      title: "YAML Reference",
      summary: "Supported file locations, document kinds, and top-level keys.",
      sections: [
        table("Provisioning paths", ["Path", "Purpose"], [
          ["config/datasources/**/*.yaml", "Provision physical datasource refs recursively."],
          ["config/datasources/**/*.yml", "Same as .yaml."],
          ["config/dashboards/**/*.yaml", "Provision dashboards recursively."],
          ["config/dashboards/**/*.yml", "Same as .yaml."]
        ]),
        table("Folder behavior", ["Behavior", "Description"], [
          [
            "Recursive loading",
            "All YAML files below the provisioning roots are loaded, regardless of folder depth."
          ],
          [
            "YAML folder",
            "Dashboards use metadata.folder. Datasource files use top-level metadata.folder, and individual datasource entries may override it with folder."
          ],
          [
            "Filesystem fallback",
            "If no YAML folder is provided, the folder falls back to the file path relative to the provisioning root."
          ],
          [
            "Root folder",
            "Files without YAML folder metadata directly under config/dashboards or config/datasources are assigned folder root."
          ],
          [
            "Tree rendering",
            "Dashboard and datasource index pages render virtual folders as collapsible tree nodes."
          ]
        ]),
        table("Shared top-level keys", ["Key", "Required", "Description"], [
          ["apiVersion", "Recommended", "Version marker. Current examples use observe/v1."],
          ["kind", "Yes", "Document kind. Supported values are Datasources and Dashboard."]
        ]),
        table("Dashboard top-level keys", ["Key", "Required", "Description"], [
          ["metadata", "Yes", "Dashboard identity and display metadata."],
          [
            "variables",
            "No",
            "Named variable definitions used by interpolation and UI controls."
          ],
          [
            "datasources",
            "No",
            "Dashboard-local datasource aliases resolved to provisioned datasource refs."
          ],
          ["queries", "Yes", "Named source and derived query definitions."],
          ["panels", "No", "Read-only visualization definitions referencing query datasets."]
        ]),
        callout(
          "Folder metadata",
          "Dashboard virtual folders should be defined with metadata.folder in YAML. Filesystem location is only a fallback. For example metadata.folder: platform/api places the dashboard under platform/api even if the file lives somewhere else."
        ),
        table("metadata options", ["Option", "Required", "Description"], [
          ["name", "Yes", "Stable dashboard identifier used in the URL /dashboards/:name."],
          ["title", "No", "Human-readable dashboard title. Falls back to metadata.name."],
          [
            "folder",
            "No",
            "Virtual dashboard folder shown in /dashboards. Supports nested paths such as services/core."
          ]
        ]),
        callout(
          "Validation rule",
          "A dashboard file must use kind: Dashboard and metadata.name must be a non-empty string."
        )
      ]
    }
  end

  defp datasource_reference do
    %{
      slug: "datasources",
      title: "Datasources",
      summary: "How physical datasource refs and dashboard-local aliases work.",
      sections: [
        text(
          "Datasource provisioning defines physical integrations by ref. Dashboards should not hard-code these refs directly in queries. Instead, dashboards define aliases such as prometheus, cloudwatch, or opensearch."
        ),
        code("Datasource file", """
        apiVersion: observe/v1
        kind: Datasources

        datasources:
          eu-p:
            type: prometheus
            url: http://localhost:9090

          eu-cw:
            type: cloudwatch
            region: eu-west-1

          eu-os:
            type: opensearch
            url: http://localhost:9200
        """),
        table("Datasource document options", ["Option", "Required", "Description"], [
          [
            "metadata.folder",
            "No",
            "Default virtual folder for all datasource refs in the file."
          ],
          ["datasources", "Yes", "Map of datasource ref names to datasource configuration."]
        ]),
        table("Per-datasource folder options", ["Option", "Required", "Description"], [
          [
            "folder",
            "No",
            "Overrides metadata.folder for one datasource ref. Supports nested virtual paths such as environments/prod."
          ]
        ]),
        table("Datasource UI", ["Route", "Description"], [
          ["/datasources", "Collapsible provisioning tree grouped by virtual folder."],
          [
            "/datasources/:name",
            "Datasource detail page with config, metadata, and raw loaded model."
          ]
        ]),
        table("Common datasource options", ["Option", "Required", "Description"], [
          [
            "type",
            "Yes",
            "Datasource adapter type. Supported model values: prometheus, cloudwatch, opensearch."
          ],
          [
            "mode",
            "No",
            "Execution mode. Use real for Prometheus HTTP execution. Omit or use mock for stubbed data."
          ],
          ["url", "Prometheus/OpenSearch", "Base URL for HTTP-backed datasources."],
          ["region", "CloudWatch", "AWS region for CloudWatch API calls."],
          [
            "timeout_ms",
            "No",
            "HTTP receive timeout for real datasource calls. Defaults to 15000."
          ]
        ]),
        table("Basic Auth options", ["Option", "Required", "Description"], [
          [
            "basic_auth.username",
            "When Basic Auth is used",
            "Username for HTTP Basic Auth. Supports ${env.NAME}."
          ],
          [
            "basic_auth.password",
            "When Basic Auth is used",
            "Password for HTTP Basic Auth. Supports ${env.NAME}; do not commit secrets to YAML."
          ]
        ]),
        code("Real Prometheus datasource", """
        apiVersion: observe/v1
        kind: Datasources

        metadata:
          folder: external/prometheus

        datasources:
          ampeco-prometheus:
            type: prometheus
            mode: real
            url: ${env.PROMETHEUS_URL}
            basic_auth:
              username: ${env.PROMETHEUS_BASIC_AUTH_USERNAME}
              password: ${env.PROMETHEUS_BASIC_AUTH_PASSWORD}
        """),
        code("Environment variables", """
        export PROMETHEUS_URL="https://your-prometheus.example.com"
        export PROMETHEUS_BASIC_AUTH_USERNAME="admin"
        export PROMETHEUS_BASIC_AUTH_PASSWORD="set-this-in-your-shell"
        """),
        table("Prometheus request options", ["Option", "Required", "Description"], [
          ["query", "Yes", "PromQL query string."],
          ["time", "No", "Evaluation timestamp for /api/v1/query."],
          ["start", "For range queries", "Range start timestamp for /api/v1/query_range."],
          ["end", "For range queries", "Range end timestamp for /api/v1/query_range."],
          ["step", "For range queries", "Query resolution step for /api/v1/query_range."]
        ]),
        table("Dashboard datasource alias options", ["Option", "Required", "Description"], [
          [
            "ref",
            "Yes",
            "Provisioned datasource ref. Supports variable interpolation, for example ${vars.region}-p."
          ]
        ]),
        code("One variable resolving multiple datasource aliases", """
        variables:
          region:
            type: enum
            values: [eu, sg, uk]
            default: eu

        datasources:
          prometheus:
            ref: ${vars.region}-p
          cloudwatch:
            ref: ${vars.region}-cw
          opensearch:
            ref: ${vars.region}-os
        """),
        callout(
          "Current implementation",
          "The UI displays resolved datasource aliases. Real network adapters are not implemented yet; the executor returns stub rows by datasource type."
        )
      ]
    }
  end

  defp ui_reference do
    %{
      slug: "ui-navigation",
      title: "UI And Navigation",
      summary: "Read-only navigation, tree views, and detail pages.",
      sections: [
        text(
          "Observe currently provides a read-only LiveView UI. YAML remains the source of truth; the UI is for browsing provisioned objects, changing runtime variables, inspecting plans, and viewing stubbed query output."
        ),
        table("Primary routes", ["Route", "Purpose"], [
          [
            "/dashboards",
            "Dashboard provisioning tree with collapsible virtual folders and dashboard leaf links."
          ],
          [
            "/dashboards/:name",
            "Dashboard detail page with variable controls, execution plan, and rendered panels."
          ],
          [
            "/datasources",
            "Datasource provisioning tree with collapsible virtual folders and datasource leaf links."
          ],
          ["/datasources/:name", "Datasource configuration detail page."],
          ["/docs", "In-app documentation site."]
        ]),
        bullets("Navigation behavior", [
          "The hamburger button in the header is the only control that opens or closes the drawer.",
          "The left drawer contains Dashboards, Datasources, and Docs.",
          "The drawer open/closed state is persisted in localStorage and survives LiveView navigation.",
          "Tree folder rows expand and collapse when clicked.",
          "Tree leaf rows open their corresponding detail page."
        ]),
        table("Dashboard controls", ["Control", "Description"], [
          [
            "Time",
            "Global relative time window for range queries. Supported values include Last 15m, 30m, 1h, 3h, 6h, 12h, 24h, and 7d."
          ],
          [
            "Start",
            "Explicit UTC start datetime. When both Start and End are valid, they override the relative Time selector."
          ],
          [
            "End",
            "Explicit UTC end datetime. Must be later than Start to activate custom time mode."
          ],
          [
            "Refresh",
            "Polling interval for re-running the dashboard query graph. Supported values are Off, 10s, 30s, 1m, and 5m."
          ],
          ["Run", "Manual refresh button that re-runs the current query graph immediately."]
        ]),
        table("Tree node behavior", ["Node", "Behavior"], [
          [
            "Folder",
            "Toggles expanded/collapsed state and hides all descendant folders/items when collapsed."
          ],
          ["Dashboard leaf", "Opens /dashboards/:name."],
          ["Datasource leaf", "Opens /datasources/:name."]
        ]),
        callout(
          "Editing",
          "Dashboard and datasource editing is intentionally not supported yet. Changes should be made in YAML files and then reloaded by the app process."
        )
      ]
    }
  end

  defp variable_reference do
    %{
      slug: "variables",
      title: "Variables",
      summary: "Dashboard variables, enum values, defaults, and interpolation syntax.",
      sections: [
        text(
          "Variables are dashboard-scoped values selected in the UI and used by the query planner. Today, variables are primarily used to resolve datasource aliases."
        ),
        table("Variable options", ["Option", "Required", "Description"], [
          ["type", "Yes", "Variable type. Supported values: enum, datasource, and label_values."],
          ["values", "Yes for enum", "Allowed values displayed in the dashboard selector."],
          [
            "datasource_type",
            "No",
            "For datasource variables, only show datasources of this type."
          ],
          [
            "datasource",
            "Yes for label_values",
            "Datasource ref or variable interpolation used to fetch label values."
          ],
          [
            "metric",
            "No",
            "For label_values variables, restrict discovery to a metric selector."
          ],
          [
            "metric_label",
            "Yes for label_values",
            "Metric label name whose values should populate the selector."
          ],
          [
            "match",
            "No",
            "Only show variable options matching this regex. Works for enum values, datasource refs, and label values."
          ],
          [
            "label",
            "No",
            "Display labels extracted from match captures, such as $1-ds, while keeping the original submitted value."
          ],
          [
            "formats",
            "No",
            "Named derived values built from match captures for dataset input bindings."
          ],
          ["default", "No", "Initial selected value. If omitted, the first value is used."]
        ]),
        code("Enum variable", """
        variables:
          region:
            type: enum
            values: [eu-charge, us-charge, internal]
            match: /(eu|us)-charge/
            label: $1-region
            default: eu-charge
        """),
        code("Datasource variable", """
        variables:
          prom:
            type: datasource
            datasource_type: prometheus
            match: /(eu|us)-charge/
            label: $1-ds
            formats:
              check: $1-ds-check
              next: $1-ds-next
            default: us-charge

        datasources:
          prometheus:
            ref: ${vars.prom}
        """),
        code("Label values variable", """
        variables:
          prom:
            type: datasource
            datasource_type: prometheus

          deployment:
            type: label_values
            datasource: ${vars.prom}
            metric: app_queue_low_running_size
            metric_label: deployment
            match: /(eu|us|uk)-charge/
            label: $1
        """),
        table("Interpolation", ["Syntax", "Description"], [
          ["${vars.region}", "Replaced with the current value of the region variable."],
          ["${vars.region.label}", "Replaced with the displayed label for the selected option."],
          ["${vars.region}-p", "Can be embedded in a larger string, producing values like eu-p."],
          [
            "${vars.prom}",
            "Can point a dashboard datasource alias at the selected datasource ref."
          ],
          [
            "${vars.prom.formats.check}",
            "Can bind a query input to a dashboard-specific derived format without coupling the query to the dashboard variable."
          ],
          [
            "${env.PROMETHEUS_URL}",
            "Replaced from the process environment. Useful for URLs and secrets."
          ]
        ]),
        callout(
          "Validation rule",
          "If a submitted variable value is not in the currently allowed options, Observe falls back to the configured default when valid, then the first valid option."
        )
      ]
    }
  end

  defp query_reference do
    %{
      slug: "queries",
      title: "Queries",
      summary: "Source queries, derived queries, graph dependencies, and validation rules.",
      sections: [
        text(
          "Queries are first-class named nodes. A query produces a dataset. A dataset can feed panels or downstream derived queries."
        ),
        table("Source query options", ["Option", "Required", "Description"], [
          ["datasource", "Yes", "Dashboard datasource alias to execute against."],
          ["request", "Yes", "Datasource-specific request payload."]
        ]),
        table("Derived query options", ["Option", "Required", "Description"], [
          ["from", "Yes", "Parent query name whose dataset should be transformed."],
          ["transform", "No", "Ordered list of transforms applied to the parent dataset."]
        ]),
        code("Source and derived query", """
        queries:
          cpu_raw:
            datasource: cloudwatch
            request:
              namespace: AWS/EC2
              metric: CPUUtilization
              period: 60
              stat: Average

          high_cpu:
            from: cpu_raw
            transform:
              - filter:
                  field: value
                  gte: 75
        """),
        code("Dashboard maps variable formats to query inputs", """
        # Query collection
        queries:
          check_metric:
            inputs:
              target:
                required: true
            datasource: prometheus
            request:
              query: app_metric{target="${inputs.target}"}

        # Dashboard
        variables:
          data:
            type: datasource
            datasource_type: prometheus
            match: /(eu|us)-charge/
            label: $1-ds
            formats:
              check: $1-ds-check
              next: $1-ds-next

        datasets:
          check_panel_data:
            query: check_metric
            inputs:
              target: ${vars.data.formats.check}
        """),
        code("Parameterized metric name from dataset inputs", """
        # Query collection
        queries:
          queue:
            inputs:
              deployment:
                required: true
              priority:
                required: true
              state:
                required: true
            datasource: prometheus
            request:
              range: true
              interval: 1m
              query: max(app_queue_${inputs.priority}_${inputs.state}_size{deployment="${inputs.deployment}"}) by (deployment)

        # Dashboard
        queryRefs:
          - queue

        datasets:
          queue_high_pending:
            query: queue
            inputs:
              deployment: ${vars.deployment}
              priority: high
              state: pending
        """),
        callout(
          "Parameterized queries",
          "Dataset inputs can be interpolated anywhere in a source request, including metric names. Use this when one query template should produce many concrete datasets."
        ),
        table("Validation rules", ["Rule", "Reason"], [
          [
            "A query cannot mix datasource/request with from/transform.",
            "Keeps source and derived query semantics explicit."
          ],
          [
            "A source query must reference a known datasource alias.",
            "Prevents runtime ambiguity."
          ],
          [
            "A derived query must reference a known parent query.",
            "Ensures the graph can be planned."
          ],
          ["Cycles are rejected.", "Execution requires a directed acyclic graph."]
        ]),
        callout(
          "Performance intent",
          "If multiple derived queries depend on the same source query, the source query should execute once and feed all derived datasets. The current planner builds this graph; real adapter caching is future work."
        )
      ]
    }
  end

  defp transform_reference do
    %{
      slug: "transforms",
      title: "Transforms",
      summary: "The supported transform DSL and examples for each transform.",
      sections: [
        text(
          "Transforms run in order over a dataset. The initial DSL is intentionally small so it can be validated and eventually optimized or pushed down into datasource-specific requests."
        ),
        table("Supported transforms", ["Transform", "Description"], [
          ["filter", "Keep rows matching comparison predicates."],
          ["select", "Keep only selected fields."],
          ["sort", "Sort rows by one field."],
          ["limit", "Keep the first N rows."]
        ]),
        table("filter options", ["Option", "Required", "Description"], [
          ["field", "Yes", "Row field to compare."],
          ["eq", "No", "Keep rows where field equals the provided value."],
          ["gt", "No", "Keep rows where numeric field is greater than the value."],
          ["gte", "No", "Keep rows where numeric field is greater than or equal to the value."],
          ["lt", "No", "Keep rows where numeric field is less than the value."],
          ["lte", "No", "Keep rows where numeric field is less than or equal to the value."]
        ]),
        code("filter", """
        transform:
          - filter:
              field: status
              gte: 500
        """),
        table("select options", ["Option", "Required", "Description"], [
          ["fields", "Yes", "List of fields to keep in each row."]
        ]),
        code("select", """
        transform:
          - select:
              fields: [timestamp, service, status, message]
        """),
        table("sort options", ["Option", "Required", "Description"], [
          ["field", "Yes", "Field to sort by."],
          ["direction", "No", "asc or desc. Defaults to asc."]
        ]),
        code("sort and limit", """
        transform:
          - sort:
              field: value
              direction: desc
          - limit: 10
        """)
      ]
    }
  end

  defp panel_reference do
    %{
      slug: "panels",
      title: "Panels",
      summary: "Read-only visualizations that consume datasets produced by queries.",
      sections: [
        text(
          "Panels are intentionally thin. They describe how to visualize a dataset, not how to fetch or prepare the data."
        ),
        table("Panel options", ["Option", "Required", "Description"], [
          ["id", "Yes", "Stable panel identifier used in DOM IDs."],
          ["title", "Yes", "Human-readable panel title."],
          [
            "description",
            "No",
            "Optional help text shown from the info icon next to the panel title."
          ],
          [
            "type",
            "Yes",
            "Visualization type. Supported values: row, table, stat, timeseries, bargauge, state-timeline."
          ],
          [
            "dataset",
            "Yes, unless datasets is set",
            "Query name whose dataset should be rendered."
          ],
          [
            "datasets",
            "Yes, unless dataset is set",
            "List of query datasets to merge for this panel."
          ],
          [
            "stacked",
            "No",
            "For timeseries panels, render visible series as a stacked area chart when true."
          ]
        ]),
        code("Panels", """
        panels:
          - id: high-cpu
            title: High CPU Instances
            type: table
            dataset: high_cpu

          - id: error-count
            title: Error Count
            type: stat
            dataset: error_logs
        """),
        code("Panel with multiple datasets", """
        datasets:
          queue_default_pending:
            query: queue
            label: Default
            inputs:
              priority: default
              state: pending

          queue_low_pending:
            query: queue
            label: Low
            inputs:
              priority: low
              state: pending

        panels:
          - id: queue-pending
            title: Queue pending size
            description: Pending queue size by priority for the selected deployment.
            type: timeseries
            stacked: true
            datasets:
              - queue_default_pending
              - queue_low_pending
              - queue_high_pending
        """),
        callout(
          "Dataset labels",
          "A dataset can define label to provide a stable display name for every row consumed from that dataset. Timeseries legends and tooltips prefer this label when present."
        ),
        table("Panel types", ["Type", "Current behavior"], [
          ["table", "Renders rows and columns from the dataset."],
          ["stat", "Renders the dataset row count as a large number."],
          [
            "timeseries",
            "Renders a D3 line chart from numeric time/value rows, or a stacked area chart when stacked is true. Drag-selecting a time range zooms all timeseries panels together."
          ],
          ["bargauge", "Renders compact HTML bar gauges from numeric value rows."],
          ["state-timeline", "Renders compact state rows from time/value series."],
          ["row", "Renders a section divider and requires no dataset."]
        ]),
        table("Panel compatibility", ["Panel", "Required dataset shape"], [
          ["timeseries", "Every row must include numeric time and value fields."],
          [
            "state-timeline",
            "Rows must include numeric time/value fields and at least one label field."
          ],
          ["bargauge", "Every row must include a numeric value field."],
          ["table", "Any row map shape."],
          ["stat", "Any row list; currently renders row count."],
          ["row", "No dataset required."]
        ]),
        callout("Validation rule", "Every panel dataset must reference an existing query name.")
      ]
    }
  end

  defp runtime_reference do
    %{
      slug: "runtime",
      title: "Runtime And Planning",
      summary: "How YAML becomes a query graph and dashboard results.",
      sections: [
        text(
          "Observe treats dashboard execution like a compiler pipeline. YAML is parsed and validated, variables are resolved, datasource aliases are resolved, and the query graph is topologically sorted before execution."
        ),
        bullets("Pipeline", [
          "Load datasource YAML files.",
          "Load dashboard YAML files.",
          "Resolve default variable values.",
          "Interpolate datasource refs such as ${vars.region}-p.",
          "Validate source and derived query shapes.",
          "Validate panel dataset references.",
          "Detect query graph cycles.",
          "Build execution order.",
          "Execute source queries and transforms.",
          "Render panels from datasets."
        ]),
        code("Graph shape", """
        cpu_raw [source: cloudwatch]
          -> high_cpu [derived: filter value >= 75]
             -> high-cpu panel

        logs_raw [source: opensearch]
          -> error_logs [derived: filter/select/limit]
             -> error-count panel
             -> error-logs panel
        """),
        callout(
          "Current limitation",
          "The graph is planned and executed sequentially today. Future work should add concurrent execution for independent source queries and result caching for expensive requests."
        )
      ]
    }
  end

  defp examples do
    %{
      slug: "examples",
      title: "Examples",
      summary: "Complete files showing the current supported configuration model.",
      sections: [
        code("config/datasources/local/regions.yaml", """
        apiVersion: observe/v1
        kind: Datasources

        metadata:
          folder: local/dev

        datasources:
          eu-p:
            type: prometheus
            url: http://localhost:9090
          eu-cw:
            type: cloudwatch
            region: eu-west-1
          eu-os:
            type: opensearch
            url: http://localhost:9200
        """),
        code("config/dashboards/services/service_overview.yaml", """
        apiVersion: observe/v1
        kind: Dashboard

        metadata:
          name: service-overview
          title: Service Overview
          folder: services/core

        variables:
          region:
            type: enum
            values: [eu, sg, uk]
            default: eu

        datasources:
          prometheus:
            ref: ${vars.region}-p
          cloudwatch:
            ref: ${vars.region}-cw
          opensearch:
            ref: ${vars.region}-os

        queries:
          logs_raw:
            datasource: opensearch
            request:
              index: app-logs-*
              query:
                match_all: {}

          error_logs:
            from: logs_raw
            transform:
              - filter:
                  field: status
                  gte: 500
              - select:
                  fields: [timestamp, service, status, message]
              - limit: 25

        panels:
          - id: error-logs
            title: Recent Error Logs
            type: table
            dataset: error_logs
        """),
        callout("Try it", "Run mix phx.server and open /docs or /dashboards/service-overview.")
      ]
    }
  end

  defp text(body), do: %{type: :text, body: body}
  defp bullets(title, items), do: %{type: :bullets, title: title, items: items}
  defp code(title, body), do: %{type: :code, title: title, body: String.trim(body)}

  defp table(title, headers, rows),
    do: %{type: :table, title: title, headers: headers, rows: rows}

  defp callout(title, body), do: %{type: :callout, title: title, body: body}
end
