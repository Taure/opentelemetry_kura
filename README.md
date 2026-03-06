# opentelemetry_kura

OpenTelemetry instrumentation for [Kura](https://github.com/Taure/kura), the Erlang database layer.

Automatically creates OpenTelemetry spans for every Kura database query by subscribing to Kura's `[kura, repo, query]` telemetry events.

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    opentelemetry_kura
]}.
```

## Setup

Call `opentelemetry_kura:setup/0` in your application's `start/2`:

```erlang
start(_Type, _Args) ->
    opentelemetry_kura:setup(),
    my_sup:start_link().
```

That's it. Every Kura query now produces an OpenTelemetry span.

## Span Attributes

Each span includes:

| Attribute | Description |
|---|---|
| `db.system` | `"postgresql"` (configurable) |
| `db.statement` | The SQL query |
| `db.operation` | `SELECT`, `INSERT`, `UPDATE`, `DELETE`, etc. |
| `db.collection.name` | Table name (when extractable) |
| `db.kura.repo` | Repo module name |
| `db.kura.num_rows` | Number of rows returned/affected |

Span names follow the `"OPERATION table"` convention (e.g. `"SELECT users"`, `"INSERT posts"`).

## Options

```erlang
opentelemetry_kura:setup(#{
    db_system => <<"postgresql">>  %% default
}).
```

## Requirements

- Kura >= 1.7.0 (telemetry events)
- OTP 28+
