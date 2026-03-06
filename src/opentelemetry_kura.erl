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

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-doc "Attach the telemetry handler with default options.".
-spec setup() -> ok.
setup() ->
    setup(#{}).

-doc """
Attach the telemetry handler with options.

Options:
- `db_system` — Database system name (default: `<<"postgresql">>`)
""".
-spec setup(map()) -> ok.
setup(Opts) ->
    telemetry:attach(
        <<"opentelemetry-kura-query">>,
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
        num_rows := integer(),
        source := binary() | undefined
    },
    map()
) -> ok.
handle_event(_Event, Measurements, Metadata, Config) ->
    #{
        query := Query,
        repo := Repo,
        result := Result,
        num_rows := NumRows,
        source := Source
    } = Metadata,
    Duration = maps:get(duration, Measurements),
    DbSystem = maps:get(db_system, Config, <<"postgresql">>),
    Operation = extract_operation(Query),
    SpanName = span_name(Operation, Source),
    Attributes = #{
        'db.system' => DbSystem,
        'db.statement' => Query,
        'db.operation' => Operation,
        'db.kura.repo' => atom_to_binary(Repo, utf8),
        'db.kura.num_rows' => NumRows
    },
    Attributes1 = maybe_add_source(Attributes, Source),
    StartTime = opentelemetry:timestamp() - Duration,
    SpanCtx = otel_tracer:start_span(
        opentelemetry:get_application_tracer(?MODULE),
        SpanName,
        #{
            start_time => StartTime,
            kind => ?SPAN_KIND_CLIENT,
            attributes => Attributes1
        }
    ),
    case Result of
        error ->
            otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"query failed">>);
        ok ->
            ok
    end,
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

-spec extract_operation(binary()) -> binary().
extract_operation(<<"SELECT", _/binary>>) -> <<"SELECT">>;
extract_operation(<<"INSERT", _/binary>>) -> <<"INSERT">>;
extract_operation(<<"UPDATE", _/binary>>) -> <<"UPDATE">>;
extract_operation(<<"DELETE", _/binary>>) -> <<"DELETE">>;
extract_operation(<<"CREATE", _/binary>>) -> <<"CREATE">>;
extract_operation(<<"DROP", _/binary>>) -> <<"DROP">>;
extract_operation(<<"ALTER", _/binary>>) -> <<"ALTER">>;
extract_operation(<<"BEGIN", _/binary>>) -> <<"BEGIN">>;
extract_operation(<<"COMMIT", _/binary>>) -> <<"COMMIT">>;
extract_operation(<<"ROLLBACK", _/binary>>) -> <<"ROLLBACK">>;
extract_operation(_) -> <<"OTHER">>.
