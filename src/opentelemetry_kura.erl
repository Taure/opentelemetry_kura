-module(opentelemetry_kura).
-moduledoc """
OpenTelemetry instrumentation for Kura.

Subscribes to Kura's `[kura, repo, query]` telemetry events and creates a
`CLIENT` span for each database query, following the stable OpenTelemetry
database semantic conventions.

```erlang
%% In your application's start/2
opentelemetry_kura:setup().
```
""".

-export([setup/0, setup/1, handle_event/4]).
-export([
    extract_operation/1,
    query_summary/2,
    span_name/1,
    namespace/2,
    error_attributes/2,
    stability_mode/1,
    format_value/1,
    sanitize_query/2
]).

-ifdef(TEST).
-export([maybe_set_error/3]).
-endif.

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-type stability() :: stable | dup.
-type connection() :: #{
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
- `db_system`: value of `db.system.name` (default: `~"postgresql"`).
- `semconv_stability`: `stable` emits only the stable database conventions,
  `dup` emits the stable attributes and the experimental ones this
  library emitted before them. Defaults to
  `dup` when `OTEL_SEMCONV_STABILITY_OPT_IN` contains `database/dup`,
  otherwise `stable`.
- `returned_rows`: when `true`, sets the opt-in `db.response.returned_rows`
  attribute (default: `false`).
- `repos`: a map from repo module to `t:connection/0`, the source of
  `db.namespace`, `server.address` and `server.port`.
- `sanitize_query`: when `true`, replaces the query text with `[SANITIZED]`.
  When a `fun/1`, applies the function to the query. Default: full query.
""".
-spec setup(map()) -> ok.
setup(Opts) ->
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
    #{
        query := Query,
        result := Result,
        error_reason := ErrorReason
    } = Metadata,
    Duration = maps:get(duration, Measurements),
    QueryText = sanitize_query(Query, Config),
    Attributes = stable_attributes(Metadata, Config),
    AllAttributes =
        case maps:get(semconv_stability, Config, stable) of
            dup -> maps:merge(legacy_attributes(QueryText, Metadata, Config), Attributes);
            stable -> Attributes
        end,
    EndTime = opentelemetry:timestamp(),
    SpanCtx = otel_tracer:start_span(
        opentelemetry:get_application_tracer(?MODULE),
        span_name(Attributes),
        #{
            start_time => EndTime - Duration,
            kind => ?SPAN_KIND_CLIENT,
            attributes => AllAttributes#{'db.query.text' => QueryText}
        }
    ),
    maybe_set_error(SpanCtx, Result, ErrorReason),
    otel_span:end_span(SpanCtx, EndTime),
    ok.

-spec stable_attributes(map(), map()) -> map().
stable_attributes(Metadata, Config) ->
    #{
        query := Query,
        params := Params,
        repo := Repo,
        result := Result,
        num_rows := NumRows,
        source := Source,
        tenant := Tenant,
        error_reason := ErrorReason
    } = Metadata,
    Connection = maps:get(Repo, maps:get(repos, Config, #{}), #{}),
    Base = #{
        'db.system.name' => maps:get(db_system, Config, ~"postgresql"),
        'db.kura.repo' => atom_to_binary(Repo, utf8),
        'db.kura.query.parameter_count' => length(Params)
    },
    Optional = [
        {'db.query.summary', query_summary(extract_operation(Query), Source)},
        {'db.namespace', namespace(maps:get(namespace, Connection, undefined), Tenant)},
        {'db.kura.tenant', attribute_tenant(Tenant)},
        {'server.address', maps:get(server_address, Connection, undefined)},
        {'server.port', server_port(Connection)},
        {'db.response.returned_rows', returned_rows(NumRows, Config)}
    ],
    maps:merge(
        error_attributes(Result, ErrorReason),
        maps:merge(Base, #{K => V || {K, V} <- Optional, V =/= undefined})
    ).

-spec legacy_attributes(binary(), map(), map()) -> map().
legacy_attributes(QueryText, Metadata, Config) ->
    #{
        query := Query,
        params := Params,
        num_rows := NumRows,
        source := Source,
        tenant := Tenant
    } = Metadata,
    Legacy = #{
        'db.system' => maps:get(db_system, Config, ~"postgresql"),
        'db.statement' => QueryText,
        'db.operation' => extract_operation(Query),
        'db.kura.num_rows' => NumRows,
        'db.query.parameter_count' => length(Params)
    },
    Optional = [{'db.collection.name', Source}, {'db.kura.tenant', legacy_tenant(Tenant)}],
    maps:merge(Legacy, #{K => V || {K, V} <- Optional, V =/= undefined}).

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
""".
-spec query_summary(binary(), binary() | undefined) -> binary() | undefined.
query_summary(~"OTHER", _Source) -> undefined;
query_summary(Operation, undefined) -> Operation;
query_summary(Operation, Source) -> <<Operation/binary, " ", Source/binary>>.

-doc """
Span name from the stable attributes: `db.query.summary`, else the target
(`db.namespace`, then `server.address[:server.port]`), else `db.system.name`.
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

-doc """
`db.namespace` in PostgreSQL's `{database}|{schema}` form. The schema is the
tenant prefix, when the query runs under one.
""".
-spec namespace(binary() | undefined, tenant()) -> binary() | undefined.
namespace(Database, {prefix, Schema}) when is_binary(Database) ->
    <<Database/binary, "|", Schema/binary>>;
namespace(undefined, {prefix, Schema}) ->
    Schema;
namespace(Database, _Tenant) ->
    Database.

-spec attribute_tenant(tenant()) -> binary() | undefined.
attribute_tenant({attribute, {Field, Value}}) ->
    iolist_to_binary([atom_to_binary(Field, utf8), ~":", format_value(Value)]);
attribute_tenant(_Tenant) ->
    undefined.

-spec legacy_tenant(tenant()) -> binary() | undefined.
legacy_tenant({prefix, Prefix}) -> Prefix;
legacy_tenant(Tenant) -> attribute_tenant(Tenant).

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

-spec maybe_set_error(opentelemetry:span_ctx(), ok | error, term() | undefined) -> ok.
maybe_set_error(SpanCtx, error, undefined) ->
    otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, ~"query failed"),
    ok;
maybe_set_error(SpanCtx, error, Reason) ->
    Msg = iolist_to_binary(io_lib:format(~"~p", [Reason])),
    otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, Msg),
    ok;
maybe_set_error(_SpanCtx, ok, _Reason) ->
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
