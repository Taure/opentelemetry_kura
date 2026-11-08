# Getting Started

## Prerequisites

- A Kura-based application with `telemetry` as a dependency
- The OpenTelemetry SDK configured in your release (e.g., `opentelemetry` + an exporter)

## Installation

Add `opentelemetry_kura` to your `rebar.config` dependencies:

```erlang
{deps, [
    {opentelemetry_kura, "~> 0.1"}
]}.
```

## Setup

Call `opentelemetry_kura:setup/0` in your application's `start/2` callback:

```erlang
-module(my_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    opentelemetry_kura:setup(),
    my_app_sup:start_link().

stop(_State) ->
    ok.
```

This attaches a telemetry handler to Kura's `[kura, repo, query]` event. Every
database query that Kura executes will now produce an OpenTelemetry span and a
`db.client.operation.duration` measurement.

To export the metric, `opentelemetry_experimental` must be running before
`setup/1` is called: the meter is looked up then, and without the SDK the
no-op meter is cached and kept. Listing it in your release's applications
starts it before your application. Without it, `setup/1` still works and only
the metric is dropped.

## Span details

Each span is a `CLIENT` span following the stable OpenTelemetry database
semantic conventions:

| Attribute          | Example                      | Description                       |
|--------------------|------------------------------|-----------------------------------|
| `db.system.name`   | `~"postgresql"`              | Database system                   |
| `db.query.text`    | `~"SELECT ... WHERE id = $1"`| The SQL query                     |
| `db.query.summary` | `~"SELECT users"`            | Operation and table               |
| `db.namespace`     | `~"my_db"`                   | Configured database name          |
| `db.kura.repo`     | `~"my_app_repo"`             | Kura repo module                  |

The span name is `db.query.summary`, for example `"SELECT users"` or
`"BEGIN"`. Failed queries set the span status to `ERROR` and add `error.type`
and, for PostgreSQL errors, `db.response.status_code` (the SQLSTATE code).

Each query is also recorded in the `db.client.operation.duration` histogram.

See the README for the full attribute list and for upgrading from 0.2.

## Configuration

Pass options to `setup/1` to customise behaviour. `db.system.name` defaults to
`postgresql`; give a kura_sqlite repo `system => ~"sqlite"` in `repos`:

```erlang
opentelemetry_kura:setup(#{
    db_system => ~"cockroachdb",
    repos => #{my_app_repo => #{namespace => ~"my_db", server_address => ~"db.internal"}}
}).
```

| Option              | Default         | Description                                         |
|---------------------|-----------------|-----------------------------------------------------|
| `db_system`         | `~"postgresql"` | `db.system.name` for repos without a `system`       |
| `semconv_stability` | `stable`        | `dup` also emits the 0.2 attribute names            |
| `returned_rows`     | `false`         | Set `db.response.returned_rows`                     |
| `repos`             | `#{}`           | Per-repo `system`, `namespace`, `server_address`, `server_port` |
| `tenant_in_namespace` | `false`       | Put a prefix tenant's schema in `db.namespace`      |
| `sanitize_query`    | unset           | `true` or `{Mod, Fun}` to redact `db.query.text`    |

## Viewing traces

opentelemetry_kura creates spans but does not export them. You need the
OpenTelemetry SDK and an exporter in your release. For example, to export to
stdout during development:

```erlang
%% rebar.config
{deps, [
    {opentelemetry, "~> 1.5"},
    {opentelemetry_exporter, "~> 1.8"}
]}.
```

```erlang
%% sys.config
[
    {opentelemetry, [
        {span_processor, batch},
        {traces_exporter, {otel_exporter_stdout, []}}
    ]}
].
```

To export the `db.client.operation.duration` metric as well, add
`opentelemetry_experimental` and configure a metric reader. The OTLP metric
exporter uses `opentelemetry_exporter`, listed above:

```erlang
%% rebar.config
{deps, [
    {opentelemetry_experimental, "~> 0.6"}
]}.
```

```erlang
%% sys.config
[
    {opentelemetry_experimental, [
        {readers, [
            #{module => otel_metric_reader,
              config => #{exporter => {otel_exporter_metrics_otlp, #{}}}}
        ]}
    ]}
].
```

For production, swap to an OTLP exporter pointing at your collector (Jaeger,
Grafana Tempo, etc.).
