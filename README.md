# opentelemetry_kura

OpenTelemetry instrumentation for [Kura](https://github.com/Taure/kura), the Erlang database layer.

Creates an OpenTelemetry span and records the `db.client.operation.duration` histogram for every Kura database query, by subscribing to Kura's `[kura, repo, query]` telemetry event. Spans and the metric follow the stable [OpenTelemetry database semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/).

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

| Attribute | Description |
|---|---|
| `db.system.name` | `"postgresql"` (configurable) |
| `db.query.text` | The SQL query. Kura binds every value as a parameter, so the text is recorded as-is unless `sanitize_query` is set |
| `db.query.summary` | `"OPERATION table"`, e.g. `"SELECT users"`. Omitted when the operation is not recognised |
| `db.namespace` | `{database}\|{schema}`: the repo's configured `namespace` and the tenant prefix, whichever are known |
| `server.address` | From the repo's `server_address` option |
| `server.port` | From the repo's `server_port` option, when `server_address` is set |
| `error.type` | On failure: the PostgreSQL SQLSTATE code; otherwise the error reason when it is an atom, the tag of a tagged tuple, or `_OTHER` |
| `db.response.status_code` | On failure: the PostgreSQL SQLSTATE code, when there is one |
| `db.response.returned_rows` | Rows returned. Opt-in: `returned_rows => true` |
| `db.kura.repo` | Repo module name |
| `db.kura.tenant` | `field:value` for an attribute-strategy tenant |
| `db.kura.query.parameter_count` | Number of bound query parameters |

The span name is `db.query.summary`; without one it falls back to `db.namespace`, then `server.address[:server.port]`, then `db.system.name`.

`db.operation.name` and `db.collection.name` are not set. Both would have to be parsed from the query text, which the conventions advise against for PostgreSQL; the parsed operation and table go into `db.query.summary` instead. The table is the first one Kura's telemetry reports for the query.

Failed queries also set the span status to `ERROR`.

## Metrics

`db.client.operation.duration` (histogram, seconds) is recorded for every query with `db.system.name`, `db.namespace`, `db.query.summary`, `error.type`, `db.response.status_code`, `server.address` and `server.port`, where set. Metrics go through `opentelemetry_api_experimental`; add `opentelemetry_experimental` and a metric reader to your release to export them, and start it before calling `setup/1`.

## Options

```erlang
opentelemetry_kura:setup(#{
    db_system => ~"postgresql",
    semconv_stability => stable,
    returned_rows => false,
    repos => #{
        my_repo => #{namespace => ~"my_db", server_address => ~"db.internal", server_port => 5432}
    },
    sanitize_query => false
}).
```

| Option | Default | Description |
|---|---|---|
| `db_system` | `~"postgresql"` | Value of `db.system.name` |
| `semconv_stability` | `stable` | `stable` or `dup`; see Upgrading |
| `returned_rows` | `false` | Set `db.response.returned_rows` |
| `repos` | `#{}` | Per-repo `namespace`, `server_address`, `server_port` |
| `sanitize_query` | unset | `true` records `[SANITIZED]`; a `fun/1` rewrites the query text |

## Upgrading from 0.2

The attributes follow the stable database conventions. The old names are gone by default:

| 0.2 | Now |
|---|---|
| `db.system` | `db.system.name` |
| `db.statement` | `db.query.text` |
| `db.operation` | `db.query.summary` (with the table) |
| `db.collection.name` | `db.query.summary` (with the operation) |
| `db.kura.num_rows` | `db.response.returned_rows` (opt-in) |
| `db.query.parameter_count` | `db.kura.query.parameter_count` |
| `db.kura.tenant` (prefix tenant) | schema part of `db.namespace` |

Span names are unchanged for recognised operations. A query with an unrecognised operation is no longer named `"OTHER table"`; it falls back as described above.

To move dashboards over gradually, emit both sets: set `OTEL_SEMCONV_STABILITY_OPT_IN=database/dup`, or pass `semconv_stability => dup`. The option takes precedence over the environment variable, which is read once, in `setup/1`. `dup` is for the transition and may be removed in a later major version.

## Requirements

- Kura >= 1.7.0 (telemetry events)
- OTP 28+
