-module(opentelemetry_kura).
-moduledoc """
OpenTelemetry instrumentation for Kura.

Subscribes to Kura's `[kura, repo, query]` telemetry events and creates
OpenTelemetry spans for each database query.

```erlang
%% In your application's start/2
opentelemetry_kura:setup().
```
""".

-export([setup/0, setup/1, handle_event/4]).
-export([extract_operation/1, span_name/2, maybe_add_source/2]).
-export([maybe_add_tenant/2, format_value/1, sanitize_query/2]).

-ifdef(TEST).
-export([maybe_set_error/3]).
-endif.

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-eqwalizer({nowarn_function, setup/1}).

-doc "Attach the telemetry handler with default options.".
-spec setup() -> ok.
setup() ->
    setup(#{}).

-doc """
Attach the telemetry handler with options.

Options:
- `db_system` — Database system name (default: `~"postgresql"`)
- `sanitize_query` — When `true`, replaces query with `[SANITIZED]`.
  When a `fun/1`, applies the function to the query. Default: include full query.
""".
-spec setup(map()) -> ok.
setup(Opts) ->
    telemetry:attach(
        ~"opentelemetry-kura-query",
        [kura, repo, query],
        fun ?MODULE:handle_event/4,
        Opts
    ),
    ok.

-doc false.
-spec handle_event(
    [atom()],
    #{duration := integer(), duration_us := integer()},
    #{
        query := binary(),
        params := list(),
        repo := module(),
        result := ok | error,
        num_rows := non_neg_integer(),
        source := binary() | undefined,
        tenant := undefined | {prefix, binary()} | {attribute, {atom(), term()}},
        error_reason := term() | undefined
    },
    map()
) -> ok.
handle_event(_Event, Measurements, Metadata, Config) ->
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
    Duration = maps:get(duration, Measurements),
    DbSystem = maps:get(db_system, Config, ~"postgresql"),
    Operation = extract_operation(Query),
    SpanName = span_name(Operation, Source),
    QueryAttr = sanitize_query(Query, Config),
    Attributes = #{
        'db.system' => DbSystem,
        'db.statement' => QueryAttr,
        'db.operation' => Operation,
        'db.kura.repo' => atom_to_binary(Repo, utf8),
        'db.kura.num_rows' => NumRows,
        'db.query.parameter_count' => length(Params)
    },
    Attributes1 = maybe_add_source(Attributes, Source),
    Attributes2 = maybe_add_tenant(Attributes1, Tenant),
    StartTime = opentelemetry:timestamp() - Duration,
    SpanCtx = otel_tracer:start_span(
        opentelemetry:get_application_tracer(?MODULE),
        SpanName,
        #{
            start_time => StartTime,
            kind => ?SPAN_KIND_CLIENT,
            attributes => Attributes2
        }
    ),
    maybe_set_error(SpanCtx, Result, ErrorReason),
    otel_span:end_span(SpanCtx, opentelemetry:timestamp()),
    ok.

-spec span_name(binary(), binary() | undefined) -> binary().
span_name(Operation, undefined) ->
    Operation;
span_name(Operation, Source) ->
    <<Operation/binary, " ", Source/binary>>.

-spec maybe_add_source(map(), binary() | undefined) -> map().
maybe_add_source(Attrs, undefined) ->
    Attrs;
maybe_add_source(Attrs, Source) ->
    Attrs#{'db.collection.name' => Source}.

-spec maybe_add_tenant(map(), undefined | {prefix, binary()} | {attribute, {atom(), term()}}) ->
    map().
maybe_add_tenant(Attrs, undefined) ->
    Attrs;
maybe_add_tenant(Attrs, {prefix, P}) ->
    Attrs#{'db.kura.tenant' => P};
maybe_add_tenant(Attrs, {attribute, {F, V}}) ->
    Attrs#{'db.kura.tenant' => iolist_to_binary([atom_to_binary(F, utf8), ~":", format_value(V)])}.

-spec format_value(term()) -> binary().
format_value(V) when is_binary(V) -> V;
format_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_value(V) when is_integer(V) -> integer_to_binary(V);
format_value(V) -> iolist_to_binary(io_lib:format(~"~p", [V])).

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
