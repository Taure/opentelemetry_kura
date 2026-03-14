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
database query that Kura executes will now produce an OpenTelemetry span.

## Span details

Each span is created as a `CLIENT` span with the following attributes:

| Attribute              | Example              | Description                        |
|------------------------|----------------------|------------------------------------|
| `db.system`            | `<<"postgresql">>`   | Database system                    |
| `db.statement`         | `<<"SELECT ...">>`   | The SQL query                      |
| `db.operation`         | `<<"SELECT">>`       | SQL operation extracted from query |
| `db.collection.name`   | `<<"users">>`        | Table name (from Kura source)      |
| `db.kura.repo`         | `<<"my_app_repo">>`  | Kura repo module                   |
| `db.kura.num_rows`     | `3`                  | Number of rows returned/affected   |

Span names follow the pattern `"OPERATION table"`, for example `"SELECT users"`
or `"INSERT posts"`. If no table source is available, the span name is just the
operation (e.g., `"BEGIN"`).

Failed queries set the span status to `ERROR` with the message `"query failed"`.

## Configuration

Pass options to `setup/1` to customize behaviour:

```erlang
opentelemetry_kura:setup(#{
    db_system => <<"cockroachdb">>
}).
```

| Option      | Default            | Description             |
|-------------|--------------------|-------------------------|
| `db_system` | `<<"postgresql">>` | Value for `db.system`   |

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

For production, swap to an OTLP exporter pointing at your collector (Jaeger,
Grafana Tempo, etc.).
