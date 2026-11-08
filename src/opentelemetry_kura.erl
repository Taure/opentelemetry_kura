-module(opentelemetry_kura).
-moduledoc """
OpenTelemetry instrumentation for Kura.

Subscribes to Kura's `[kura, repo, query]` telemetry events, creates a
`CLIENT` span for each database query and records the
`db.client.operation.duration` histogram, following the stable OpenTelemetry
database semantic conventions.

```erlang
%% In your application's start/2
opentelemetry_kura:setup().
```
""".

-export([setup/0, setup/1, handle_event/4]).
-export([extract_operation/1, format_value/1, sanitize_query/2]).

-ifdef(TEST).
-export([
    query_summary/2,
    span_name/1,
    namespace/2,
    error_attributes/2,
    stability_mode/1
]).
-endif.

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(DURATION_METRIC, 'db.client.operation.duration').
-define(METRIC_ATTRIBUTES, [
    'db.system.name',
    'db.namespace',
    'db.query.summary',
    'db.response.status_code',
    'error.type',
    'server.address',
    'server.port'
]).

-type stability() :: stable | dup.
-type connection() :: #{
    system => binary(),
    namespace => binary(),
    server_address => binary(),
    server_port => inet:port_number()
}.
-type tenant() :: undefined | {prefix, binary()} | {attribute, {atom(), term()}}.

-export_type([stability/0, connection/0]).

-doc "Attach the telemetry handler with default options.".
-spec setup() -> ok.
setup() ->
    setup(#{}).

-doc """
Attach the telemetry handler with options.

Options:
- `db_system`: value of `db.system.name` for repos without a `system` in
  `repos` (default: `~"postgresql"`).
- `semconv_stability`: `stable` emits only the stable database conventions,
  `dup` emits the stable attributes and the experimental ones this
  library emitted before them. Defaults to
  `dup` when `OTEL_SEMCONV_STABILITY_OPT_IN` contains `database/dup`,
  otherwise `stable`.
- `returned_rows`: when `true`, sets the opt-in `db.response.returned_rows`
  attribute (default: `false`).
- `repos`: a map from repo module to `t:connection/0`, the source of
  `db.system.name` (`system`, e.g. `~"sqlite"` for a kura_sqlite repo),
  `db.namespace`, `server.address` and `server.port`.
- `tenant_in_namespace`: when `true`, a prefix tenant's schema is appended to
  the span's `db.namespace` (`{database}|{schema}`) instead of being recorded
  as `db.kura.tenant`. It never reaches the span name or the metric
  (default: `false`).
- `sanitize_query`: when `true`, replaces the query text with `[SANITIZED]`.
  When a `fun/1`, applies the function to the query. Default: full query.
""".
-spec setup(map()) -> ok.
setup(Opts) ->
    _ = otel_meter:create_histogram(meter(), ?DURATION_METRIC, #{
        description => ~"Duration of database client operations.",
        unit => s,
        advisory_params => #{
            explicit_bucket_boundaries => [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10]
        }
    }),
    Stability = maps:get(
        semconv_stability, Opts, stability_mode(os:getenv("OTEL_SEMCONV_STABILITY_OPT_IN"))
    ),
    _ = telemetry:attach(
        ~"opentelemetry-kura-query",
        [kura, repo, query],
        fun ?MODULE:handle_event/4,
        Opts#{semconv_stability => Stability}
    ),
    ok.

-doc false.
%% Measurements and metadata are whatever kura's `[kura, repo, query]` event
%% carries, and the config is the map setup/1 attached; telemetry hands all
%% three back untyped.
-spec handle_event(telemetry:event_name(), dynamic(), dynamic(), dynamic()) -> ok.
handle_event(_Event, Measurements, Metadata, Config) ->
    #{query := Query} = Metadata,
    Duration = maps:get(duration, Measurements),
    QueryText = sanitize_query(Query, Config),
    Target = target_attributes(Metadata, Config),
    Attributes = maps:merge(Target, span_attributes(Metadata, Config)),
    AllAttributes =
        case maps:get(semconv_stability, Config, stable) of
            dup -> maps:merge(legacy_attributes(QueryText, Metadata, Config), Attributes);
            stable -> Attributes
        end,
    EndTime = opentelemetry:timestamp(),
    SpanCtx = otel_tracer:start_span(
        opentelemetry:get_application_tracer(?MODULE),
        span_name(Target),
        #{
            start_time => EndTime - Duration,
            kind => ?SPAN_KIND_CLIENT,
            attributes => AllAttributes#{'db.query.text' => QueryText}
        }
    ),
    maybe_set_error(SpanCtx, Target),
    otel_span:end_span(SpanCtx, EndTime),
    Seconds = erlang:convert_time_unit(Duration, native, nanosecond) / 1.0e9,
    _ = otel_histogram:record(
        otel_ctx:get_current(),
        meter(),
        ?DURATION_METRIC,
        Seconds,
        maps:with(?METRIC_ATTRIBUTES, Target)
    ),
    ok.

-spec meter() -> otel_meter:t().
meter() ->
    #instrumentation_scope{} = Scope = opentelemetry:get_application_scope(?MODULE),
    opentelemetry_experimental:get_meter(Scope).

-spec target_attributes(map(), map()) -> map().
target_attributes(Metadata, Config) ->
    #{
        query := Query,
        repo := Repo,
        result := Result,
        source := Source,
        tenant := Tenant,
        error_reason := ErrorReason
    } = Metadata,
    Connection = connection(Repo, Config),
    Optional = [
        {'db.query.summary',
            query_summary(extract_operation(Query), summary_source(Source, Tenant))},
        {'db.namespace', maps:get(namespace, Connection, undefined)},
        {'server.address', maps:get(server_address, Connection, undefined)},
        {'server.port', server_port(Connection)}
    ],
    maps:merge(
        error_attributes(Result, ErrorReason),
        defined(Optional, #{'db.system.name' => db_system(Connection, Config)})
    ).

-spec span_attributes(map(), map()) -> map().
span_attributes(Metadata, Config) ->
    #{
        params := Params,
        repo := Repo,
        num_rows := NumRows,
        tenant := Tenant
    } = Metadata,
    Connection = connection(Repo, Config),
    Base = #{
        'db.kura.repo' => atom_to_binary(Repo, utf8),
        'db.kura.query.parameter_count' => length(Params)
    },
    Optional = [
        {'db.response.returned_rows', returned_rows(NumRows, Config)}
        | tenant_attributes(maps:get(namespace, Connection, undefined), Tenant, Config)
    ],
    defined(Optional, Base).

-spec connection(atom(), map()) -> connection().
connection(Repo, Config) ->
    maps:get(Repo, maps:get(repos, Config, #{}), #{}).

-spec db_system(connection(), map()) -> binary().
db_system(#{system := System}, _Config) -> System;
db_system(_Connection, Config) -> maps:get(db_system, Config, ~"postgresql").

-spec defined([{atom(), term()}], map()) -> map().
defined(Optional, Attributes) ->
    maps:merge(Attributes, #{K => V || {K, V} <- Optional, V =/= undefined}).

-spec summary_source(binary() | undefined, tenant()) -> binary() | undefined.
summary_source(_Source, {prefix, _Schema}) -> undefined;
summary_source(Source, _Tenant) -> Source.

-spec tenant_attributes(binary() | undefined, tenant(), map()) -> [{atom(), term()}].
tenant_attributes(Database, {prefix, Schema}, #{tenant_in_namespace := true}) ->
    [{'db.namespace', namespace(Database, Schema)}];
tenant_attributes(_Database, Tenant, _Config) ->
    [{'db.kura.tenant', tenant_label(Tenant)}].

-spec legacy_attributes(binary(), map(), map()) -> map().
legacy_attributes(QueryText, Metadata, Config) ->
    #{
        query := Query,
        params := Params,
        repo := Repo,
        num_rows := NumRows,
        source := Source,
        tenant := Tenant
    } = Metadata,
    Legacy = #{
        'db.system' => db_system(connection(Repo, Config), Config),
        'db.statement' => QueryText,
        'db.operation' => extract_operation(Query),
        'db.kura.num_rows' => NumRows,
        'db.query.parameter_count' => length(Params)
    },
    defined([{'db.collection.name', Source}, {'db.kura.tenant', tenant_label(Tenant)}], Legacy).

-doc """
Resolve the semantic-convention mode from the value of
`OTEL_SEMCONV_STABILITY_OPT_IN`: `dup` when the comma-separated list contains
`database/dup`, otherwise `stable`.
""".
-spec stability_mode(string() | false) -> stability().
stability_mode(false) ->
    stable;
stability_mode(OptIn) ->
    Values = [string:trim(V) || V <- string:split(OptIn, ",", all)],
    case lists:member("database/dup", Values) of
        true -> dup;
        false -> stable
    end.

-doc """
Low-cardinality `db.query.summary`: the operation followed by the table kura
reports for the query. `undefined` when the operation is not recognised.
Under a prefix tenant the table is left out, since kura then reports the
tenant schema.
""".
-spec query_summary(binary(), binary() | undefined) -> binary() | undefined.
query_summary(~"OTHER", _Source) -> undefined;
query_summary(Operation, undefined) -> Operation;
query_summary(Operation, Source) -> <<Operation/binary, " ", Source/binary>>.

-doc """
Span name from the tenant-free attributes: `db.query.summary`, else the
target (`db.namespace`, then `server.address[:server.port]`), else
`db.system.name`.
""".
-spec span_name(map()) -> binary().
span_name(#{'db.query.summary' := Summary}) ->
    Summary;
span_name(#{'db.namespace' := Namespace}) ->
    Namespace;
span_name(#{'server.address' := Address, 'server.port' := Port}) ->
    <<Address/binary, ":", (integer_to_binary(Port))/binary>>;
span_name(#{'server.address' := Address}) ->
    Address;
span_name(#{'db.system.name' := DbSystem}) ->
    DbSystem.

-doc "`db.namespace` in PostgreSQL's `{database}|{schema}` form.".
-spec namespace(binary() | undefined, binary()) -> binary().
namespace(undefined, Schema) -> Schema;
namespace(Database, Schema) -> <<Database/binary, "|", Schema/binary>>.

-spec tenant_label(tenant()) -> binary() | undefined.
tenant_label({prefix, Prefix}) ->
    Prefix;
tenant_label({attribute, {Field, Value}}) ->
    iolist_to_binary([atom_to_binary(Field, utf8), ~":", format_value(Value)]);
tenant_label(undefined) ->
    undefined.

-spec server_port(connection()) -> inet:port_number() | undefined.
server_port(#{server_address := _, server_port := Port}) -> Port;
server_port(_Connection) -> undefined.

-spec returned_rows(non_neg_integer(), map()) -> non_neg_integer() | undefined.
returned_rows(NumRows, #{returned_rows := true}) -> NumRows;
returned_rows(_NumRows, _Config) -> undefined.

-doc """
`error.type` and `db.response.status_code` for a failed query. A PostgreSQL
error sets both to its SQLSTATE code. Any other reason sets `error.type` to
the reason when it is an atom, to the tag of a tagged tuple, or to `_OTHER`.
""".
-spec error_attributes(ok | error, term()) -> map().
error_attributes(ok, _Reason) ->
    #{};
error_attributes(error, {pgsql_error, #{code := Code}}) when is_binary(Code) ->
    #{'error.type' => Code, 'db.response.status_code' => Code};
error_attributes(error, Reason) when is_atom(Reason), Reason =/= undefined ->
    #{'error.type' => atom_to_binary(Reason, utf8)};
error_attributes(error, {Tag, _}) when is_atom(Tag) ->
    #{'error.type' => atom_to_binary(Tag, utf8)};
error_attributes(error, _Reason) ->
    #{'error.type' => ~"_OTHER"}.

-doc false.
-spec format_value(term()) -> binary().
format_value(V) when is_binary(V) -> V;
format_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_value(V) when is_integer(V) -> integer_to_binary(V);
format_value(V) -> iolist_to_binary(io_lib:format(~"~p", [V])).

-doc false.
-spec sanitize_query(binary(), map()) -> binary().
sanitize_query(Query, #{sanitize_query := Fun}) when is_function(Fun, 1) -> Fun(Query);
sanitize_query(_Query, #{sanitize_query := true}) -> ~"[SANITIZED]";
sanitize_query(Query, _Config) -> Query.

-spec maybe_set_error(opentelemetry:span_ctx(), map()) -> ok.
maybe_set_error(SpanCtx, #{'error.type' := ErrorType}) ->
    _ = otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, ErrorType),
    ok;
maybe_set_error(_SpanCtx, _Attributes) ->
    ok.

-doc false.
-spec extract_operation(binary()) -> binary().
extract_operation(<<"SELECT", _/binary>>) -> ~"SELECT";
extract_operation(<<"INSERT", _/binary>>) -> ~"INSERT";
extract_operation(<<"UPDATE", _/binary>>) -> ~"UPDATE";
extract_operation(<<"DELETE", _/binary>>) -> ~"DELETE";
extract_operation(<<"CREATE", _/binary>>) -> ~"CREATE";
extract_operation(<<"DROP", _/binary>>) -> ~"DROP";
extract_operation(<<"ALTER", _/binary>>) -> ~"ALTER";
extract_operation(<<"BEGIN", _/binary>>) -> ~"BEGIN";
extract_operation(<<"COMMIT", _/binary>>) -> ~"COMMIT";
extract_operation(<<"ROLLBACK", _/binary>>) -> ~"ROLLBACK";
extract_operation(_) -> ~"OTHER".
