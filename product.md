# Observe Product Requirements

## Product Vision

Observe is a YAML-provisioned observability dashboard system that fixes a core Grafana limitation: queries are treated as configuration hidden inside panels instead of reusable, composable product primitives.

Observe makes queries first-class citizens. Dashboards consume reusable datasets produced by a query graph. Panels visualize datasets; they do not own the data-fetching logic.

## Target User

- Platform engineers maintaining internal observability tooling.
- SREs building dashboards across multiple regions, accounts, and environments.
- Backend engineers who need fast dashboards over Prometheus, CloudWatch, and OpenSearch data.
- Teams that prefer GitOps, reviewable dashboard changes, and repeatable provisioning.

## Initial Product Scope

- Local/internal tool first.
- Phoenix LiveView read-only dashboard UI.
- YAML as the source of truth for datasources and dashboards.
- No dashboard editing UI in the first version.
- No authentication or authorization in the first version.
- Clean model, no Grafana JSON compatibility requirement.

## Core Problems To Solve

### Problem 1: Queries Are Not First-Class In Grafana

In Grafana, a dashboard contains panels and panels contain queries. This makes the query a private implementation detail of the panel.

Consequences:

- The same source query cannot be reused naturally by multiple panels.
- Derived queries cannot depend on other queries cleanly.
- A large expensive CloudWatch or OpenSearch request may be repeated by multiple panels.
- Transformations are often duplicated across panels.
- It is hard to understand why a dashboard is slow because there is no clear query dependency graph.

Observe requirement:

- Queries must be top-level dashboard entities.
- Queries must be named and reusable.
- A query must be able to depend on another query.
- The runtime must build an explicit query DAG.
- Source queries should execute once and feed multiple derived datasets.
- Panels must reference datasets by name.

### Problem 2: Provisioning Is Not Expressive Enough

Grafana supports dashboard JSON provisioning, but cross-datasource dashboard configuration often requires duplicated variables and manual datasource selection.

Example pain:

- Prometheus datasources: `eu-p`, `sg-p`, `uk-p`
- CloudWatch datasources: `eu-cw`, `sg-cw`, `uk-cw`
- OpenSearch datasources: `eu-os`, `sg-os`, `uk-os`

The user should select one region variable, such as `eu`, and the dashboard should resolve all relevant datasource aliases automatically.

Observe requirement:

- Dashboards must support variables.
- Datasource aliases must support interpolation.
- A single variable must be able to resolve multiple datasource refs.
- YAML must be the source of truth.
- YAML should be concise, reviewable, and suitable for Git.

## Product Principles

- Queries are first-class citizens.
- Panels consume datasets; panels do not own source queries.
- YAML is the provisioning source of truth.
- The runtime should explain what it is doing through a visible execution plan.
- Expensive source queries should be deduplicated by graph planning.
- Transformations should be explicit and reusable.
- The clean model is more important than Grafana compatibility.
- Start with a small correct core instead of a broad clone.

## MVP Requirements

### Provisioning

- Load datasource YAML files recursively from `config/datasources/**/*.yaml` and `config/datasources/**/*.yml`.
- Load dashboard YAML files recursively from `config/dashboards/**/*.yaml` and `config/dashboards/**/*.yml`.
- Read virtual folder metadata from YAML.
- Fall back to filesystem folder paths only when YAML folder metadata is not provided.
- Display provisioned dashboards and datasources as collapsible virtual folder trees.
- Validate the shape of datasource and dashboard files.
- Keep provisioned state in memory initially.
- Support reload in the process API; UI reload controls can be added later.

### Datasources

- Support the datasource types `prometheus`, `cloudwatch`, and `opensearch` in the model.
- Store datasource configuration by ref name.
- Provide a datasource detail page showing configuration, provisioning metadata, and the raw loaded model.
- Resolve dashboard-local datasource aliases to provisioned refs.
- Support real Prometheus execution over the HTTP API when a datasource uses `mode: real`.
- Keep CloudWatch and OpenSearch execution stubbed until their real adapters are implemented.

### Variables

- Support enum variables.
- Support default values.
- Validate selected values against allowed enum values.
- Support interpolation with the syntax `${vars.name}`.
- Support interpolation in datasource refs.

### Queries

- Support source queries with `datasource` and `request`.
- Support derived queries with `from` and `transform`.
- Reject queries that mix source and derived shapes.
- Reject unknown datasource aliases.
- Reject unknown query dependencies.
- Reject cycles in the query graph.
- Produce a deterministic execution order.

### Transforms

- Support `filter`.
- Support `select`.
- Support `sort`.
- Support `limit`.
- Keep the transform DSL small and explicit at first.
- Avoid SQL as the initial transform language.

### Panels

- Support `table` panels.
- Support `stat` panels.
- Support `timeseries` panels rendered with D3.
- Support runtime panel/result compatibility validation.
- Validate every panel references an existing dataset.
- Display row counts for visible datasets.

### UI

- Provide a dashboard list at `/dashboards`.
- Provide dashboard detail pages at `/dashboards/:name`.
- Provide a datasource inventory page at `/datasources`.
- Provide datasource detail pages at `/datasources/:name`.
- Provide collapsible tree views for dashboards and datasources based on provisioning folders.
- Provide a hamburger-controlled left drawer navigation with Dashboards, Datasources, and Docs.
- Preserve drawer open/closed state across LiveView navigation until the hamburger is clicked.
- Provide variable controls.
- Provide global dashboard time window controls for range queries.
- Provide explicit start/end time controls that override relative ranges when valid.
- Provide dashboard polling controls with selectable refresh intervals.
- Re-run the query graph when variables change.
- Re-run the query graph when the time window changes or polling fires.
- Show datasource alias resolution.
- Show query execution order.
- Render provisioned panels.
- Render timeseries panels client-side with D3.
- Provide a documentation site at `/docs`.

### Documentation

- Include product requirements in `product.md`.
- Provide an in-app documentation site.
- Explain core concepts.
- Explain every YAML top-level key used by datasources and dashboards.
- Explain every supported datasource option.
- Explain every supported variable option.
- Explain every supported query option.
- Explain every supported transform option.
- Explain every supported panel option.
- Provide complete examples.

## Non-Goals For The First Version

- Dashboard editing UI.
- User accounts.
- Team permissions.
- OAuth/SAML/SSO.
- Grafana dashboard JSON import.
- Alerting.
- Real Prometheus, CloudWatch, or OpenSearch calls.
- Distributed caching.
- Persistent database storage.
- Plugin system.

## Future Requirements

- Real OpenSearch adapter using `Req`.
- Real CloudWatch adapter.
- Query result caching.
- Query execution concurrency.
- Query explain/debug views.
- Dashboard reload controls.
- Git sync or file watcher.
- Alert evaluation over query datasets.
- Auth and multi-team support.
- Better charting with a JS chart hook such as uPlot.
- Optional database persistence for user preferences and runtime metadata.

## Example Model

```yaml
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
  cpu_raw:
    datasource: cloudwatch
    request:
      namespace: AWS/EC2
      metric: CPUUtilization

  high_cpu:
    from: cpu_raw
    transform:
      - filter:
          field: value
          gte: 75

panels:
  - id: high-cpu
    title: High CPU Instances
    type: table
    dataset: high_cpu
```

This model ensures `cpu_raw` can execute once and feed multiple derived datasets and panels.
