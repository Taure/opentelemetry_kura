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
| `db.system.name` | The repo's `system` from `repos`, else `db_system`, else `"postgresql"`. Kura's telemetry does not say which backend ran the query, so a kura_sqlite repo needs `system => ~"sqlite"` |
| `db.query.text` | The SQL query. Kura binds every value as a parameter, so the text is recorded as-is unless `sanitize_query` is set |
| `db.query.summary` | `"OPERATION table"`, e.g. `"SELECT users"`. Under a prefix tenant, the operation only. Omitted when the operation is not recognised |
| `db.namespace` | The repo's configured `namespace`. With `tenant_in_namespace => true`, a prefix tenant's schema is appended: `{database}\|{schema}` |
| `server.address` | From the repo's `server_address` option |
| `server.port` | From the repo's `server_port` option, when `server_address` is set |
| `error.type` | On failure: the PostgreSQL SQLSTATE code; otherwise the error reason when it is an atom, the tag of a tagged tuple, or `_OTHER` |
| `db.response.status_code` | On failure: the PostgreSQL SQLSTATE code, when there is one |
| `db.response.returned_rows` | Rows returned. Opt-in: `returned_rows => true` |
| `db.kura.repo` | Repo module name |
| `db.kura.tenant` | `field:value` for an attribute-strategy tenant; the schema for a prefix tenant unless `tenant_in_namespace` is set |
| `db.kura.query.parameter_count` | Number of bound query parameters |

The span name is `db.query.summary`; without one it falls back to the configured `namespace`, then `server.address[:server.port]`, then `db.system.name`. Tenant values never appear in span names or metric attributes: under a prefix tenant Kura reports the tenant schema as the query's table, so it is left out of the summary.

`db.operation.name` and `db.collection.name` are not set. Both would have to be parsed from the query text, which the conventions advise against for PostgreSQL; the parsed operation and table go into `db.query.summary` instead. The table is the first one Kura's telemetry reports for the query.

Failed queries also set the span status to `ERROR`, with the `error.type` value as its description. The error reason itself is never recorded, since a PostgreSQL error can carry row values.

## Metrics

`db.client.operation.duration` (histogram, seconds) is recorded for every query with `db.system.name`, `db.namespace` (the configured `namespace`, never a tenant schema), `db.query.summary`, `error.type`, `db.response.status_code`, `server.address` and `server.port`, where set. Metrics go through `opentelemetry_api_experimental`; add `opentelemetry_experimental` and a metric reader to your release to export them, and start it before calling `setup/1`.

## Options

```erlang
opentelemetry_kura:setup(#{
    db_system => ~"postgresql",
    semconv_stability => stable,
    returned_rows => false,
    repos => #{
        my_repo => #{namespace => ~"my_db", server_address => ~"db.internal", server_port => 5432},
        cache_repo => #{system => ~"sqlite", namespace => ~"cache.db"}
    },
    tenant_in_namespace => false
}).
```

| Option | Default | Description |
|---|---|---|
| `db_system` | `~"postgresql"` | `db.system.name` for repos without a `system` |
| `semconv_stability` | `stable` | `stable` or `dup`; see Upgrading |
| `returned_rows` | `false` | Set `db.response.returned_rows` |
| `repos` | `#{}` | Per-repo `system`, `namespace`, `server_address`, `server_port` |
| `tenant_in_namespace` | `false` | Put a prefix tenant's schema in the span's `db.namespace` instead of `db.kura.tenant` |
| `sanitize_query` | unset | `true` records `[SANITIZED]`; a `fun/1` rewrites the query text |

## Upgrading from 0.2

The attributes follow the stable database conventions. The old names are gone by default:

| 0.2 | Now |
|---|---|
| `db.system` | `db.system.name` |
| `db.statement` | `db.query.text` |
| `db.operation` | `db.query.summary` (with the table) |
| `db.collection.name` | `db.query.summary` (with the operation; without it under a prefix tenant) |
| `db.kura.num_rows` | `db.response.returned_rows` (opt-in) |
| `db.query.parameter_count` | `db.kura.query.parameter_count` |

Span names are unchanged for recognised operations, except under a prefix tenant, where the span is named after the operation alone (`"SELECT"` rather than `"SELECT acme"`). A query with an unrecognised operation is no longer named `"OTHER table"`; it falls back as described above.

To move dashboards over gradually, emit both sets: set `OTEL_SEMCONV_STABILITY_OPT_IN=database/dup`, or pass `semconv_stability => dup`. The option takes precedence over the environment variable, which is read once, in `setup/1`. `dup` is for the transition and may be removed in a later major version.

## Requirements

- Kura >= 1.7.0 (telemetry events)
- OTP 28+
