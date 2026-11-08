-module(opentelemetry_kura_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic_query/1,
    returned_rows_opt_in/1,
    connection_attributes/1,
    query_with_tenant/1,
    query_error/1,
    unknown_operation/1,
    sanitized_query/1,
    dup_mode_option/1,
    dup_mode_env/1,
    duration_metric/1
]).

-define(LEGACY_ATTRIBUTES, [
    'db.system',
    'db.statement',
    'db.operation',
    'db.kura.num_rows',
    'db.query.parameter_count',
    'db.collection.name'
]).

all() ->
    [
        basic_query,
        returned_rows_opt_in,
        connection_attributes,
        query_with_tenant,
        query_error,
        unknown_operation,
        sanitized_query,
        dup_mode_option,
        dup_mode_env,
        duration_metric
    ].

init_per_suite(Config) ->
    os:unsetenv("OTEL_SEMCONV_STABILITY_OPT_IN"),
    {ok, _} = application:ensure_all_started(telemetry),
    application:load(opentelemetry),
    application:set_env(opentelemetry, traces_exporter, none),
    application:set_env(opentelemetry, processors, [
        {otel_simple_processor, #{}}
    ]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    ok = application:set_env(opentelemetry_experimental, readers, [
        #{
            module => otel_metric_reader,
            config => #{exporter => {opentelemetry_kura_metric_exporter, []}}
        }
    ]),
    {ok, _} = application:ensure_all_started(opentelemetry_experimental),
    Config.

end_per_suite(_Config) ->
    application:stop(opentelemetry_experimental),
    application:stop(opentelemetry),
    ok.

init_per_testcase(_TestCase, Config) ->
    otel_simple_processor:set_exporter(otel_exporter_pid, self()),
    persistent_term:put(opentelemetry_kura_metric_pid, self()),
    Config.

end_per_testcase(_TestCase, _Config) ->
    telemetry:detach(~"opentelemetry-kura-query"),
    persistent_term:erase(opentelemetry_kura_metric_pid),
    os:unsetenv("OTEL_SEMCONV_STABILITY_OPT_IN"),
    ok.

basic_query(_Config) ->
    opentelemetry_kura:setup(),
    fire_event(metadata(#{})),
    {Name, Kind, Status, Attrs} = receive_span(),
    ?assertEqual(~"SELECT users", Name),
    ?assertEqual(?SPAN_KIND_CLIENT, Kind),
    ?assertEqual(
        #{
            'db.system.name' => ~"postgresql",
            'db.query.text' => ~"SELECT * FROM users WHERE id = $1",
            'db.query.summary' => ~"SELECT users",
            'db.kura.repo' => ~"my_repo",
            'db.kura.query.parameter_count' => 1
        },
        Attrs
    ),
    ?assertEqual(undefined, Status),
    ok.

returned_rows_opt_in(_Config) ->
    opentelemetry_kura:setup(#{returned_rows => true}),
    fire_event(metadata(#{num_rows => 7})),
    Attrs = span_attributes(receive_span()),
    ?assertEqual(7, maps:get('db.response.returned_rows', Attrs)),
    ok.

connection_attributes(_Config) ->
    opentelemetry_kura:setup(#{
        repos => #{
            my_repo => #{
                namespace => ~"app_db", server_address => ~"db.internal", server_port => 6432
            },
            other_repo => #{server_port => 6432}
        }
    }),
    fire_event(metadata(#{})),
    Attrs = span_attributes(receive_span()),
    ?assertEqual(~"app_db", maps:get('db.namespace', Attrs)),
    ?assertEqual(~"db.internal", maps:get('server.address', Attrs)),
    ?assertEqual(6432, maps:get('server.port', Attrs)),

    fire_event(metadata(#{repo => other_repo})),
    OtherAttrs = span_attributes(receive_span()),
    ?assertNot(maps:is_key('server.port', OtherAttrs)),
    ?assertNot(maps:is_key('db.namespace', OtherAttrs)),

    fire_event(metadata(#{query => ~"WITH x AS (SELECT 1) SELECT * FROM x", source => undefined})),
    ?assertEqual(~"app_db", span_name(receive_span())),
    ok.

query_with_tenant(_Config) ->
    opentelemetry_kura:setup(#{repos => #{my_repo => #{namespace => ~"app_db"}}}),
    fire_event(metadata(#{tenant => {prefix, ~"acme"}})),
    Attrs = span_attributes(receive_span()),
    ?assertEqual(~"app_db|acme", maps:get('db.namespace', Attrs)),
    ?assertNot(maps:is_key('db.kura.tenant', Attrs)),

    fire_event(metadata(#{tenant => {attribute, {org_id, 42}}})),
    Attrs2 = span_attributes(receive_span()),
    ?assertEqual(~"org_id:42", maps:get('db.kura.tenant', Attrs2)),
    ?assertEqual(~"app_db", maps:get('db.namespace', Attrs2)),
    ok.

query_error(_Config) ->
    opentelemetry_kura:setup(),
    fire_event(
        metadata(#{
            query => ~"INSERT INTO users (name) VALUES ($1)",
            result => error,
            num_rows => 0,
            error_reason => {pgsql_error, #{code => ~"23505", constraint => ~"users_name_key"}}
        })
    ),
    {_Name, _Kind, Status, Attrs} = receive_span(),
    ?assertMatch({?OTEL_STATUS_ERROR, _}, Status),
    ?assertEqual(~"23505", maps:get('error.type', Attrs)),
    ?assertEqual(~"23505", maps:get('db.response.status_code', Attrs)),
    ok.

unknown_operation(_Config) ->
    opentelemetry_kura:setup(),
    fire_event(metadata(#{query => ~"EXPLAIN SELECT 1", source => undefined, params => []})),
    {Name, _Kind, _Status, Attrs} = receive_span(),
    ?assertEqual(~"postgresql", Name),
    ?assertNot(maps:is_key('db.query.summary', Attrs)),
    ok.

sanitized_query(_Config) ->
    opentelemetry_kura:setup(#{sanitize_query => true}),
    fire_event(metadata(#{query => ~"SELECT secret FROM passwords", source => ~"passwords"})),
    Attrs = span_attributes(receive_span()),
    ?assertEqual(~"[SANITIZED]", maps:get('db.query.text', Attrs)),
    ok.

dup_mode_option(_Config) ->
    opentelemetry_kura:setup(#{semconv_stability => dup, sanitize_query => true}),
    fire_event(metadata(#{tenant => {prefix, ~"acme"}})),
    {Name, _Kind, _Status, Attrs} = receive_span(),
    ?assertEqual(~"SELECT users", Name),
    ?assertMatch(
        #{
            'db.system' := ~"postgresql",
            'db.statement' := ~"[SANITIZED]",
            'db.operation' := ~"SELECT",
            'db.collection.name' := ~"users",
            'db.kura.num_rows' := 1,
            'db.query.parameter_count' := 1,
            'db.kura.tenant' := ~"acme",
            'db.system.name' := ~"postgresql",
            'db.query.text' := ~"[SANITIZED]",
            'db.query.summary' := ~"SELECT users",
            'db.namespace' := ~"acme"
        },
        Attrs
    ),
    ok.

dup_mode_env(_Config) ->
    os:putenv("OTEL_SEMCONV_STABILITY_OPT_IN", "http,database/dup"),
    opentelemetry_kura:setup(),
    fire_event(metadata(#{})),
    Attrs = span_attributes(receive_span()),
    [?assert(maps:is_key(Key, Attrs)) || Key <- ?LEGACY_ATTRIBUTES],
    ?assert(maps:is_key('db.system.name', Attrs)),

    telemetry:detach(~"opentelemetry-kura-query"),
    os:putenv("OTEL_SEMCONV_STABILITY_OPT_IN", "database"),
    opentelemetry_kura:setup(),
    fire_event(metadata(#{})),
    StableAttrs = span_attributes(receive_span()),
    [?assertNot(maps:is_key(Key, StableAttrs)) || Key <- ?LEGACY_ATTRIBUTES],

    telemetry:detach(~"opentelemetry-kura-query"),
    os:putenv("OTEL_SEMCONV_STABILITY_OPT_IN", "database/dup"),
    opentelemetry_kura:setup(#{semconv_stability => stable}),
    fire_event(metadata(#{})),
    OverriddenAttrs = span_attributes(receive_span()),
    ?assertNot(maps:is_key('db.statement', OverriddenAttrs)),
    ok.

duration_metric(_Config) ->
    opentelemetry_kura:setup(#{
        repos => #{metric_repo => #{namespace => ~"metric_db", server_address => ~"db.internal"}}
    }),
    fire_event(
        metadata(#{repo => metric_repo, source => ~"metric_events"}),
        erlang:convert_time_unit(250, millisecond, native)
    ),
    fire_event(
        metadata(#{
            repo => metric_repo,
            source => ~"metric_events",
            result => error,
            error_reason => {pgsql_error, #{code => ~"57014"}}
        }),
        erlang:convert_time_unit(10, millisecond, native)
    ),
    _ = receive_span(),
    _ = receive_span(),
    otel_meter_server:force_flush(),
    Datapoints = receive_datapoints('db.client.operation.duration'),
    [Ok] = [
        DP
     || #{attributes := #{'db.namespace' := ~"metric_db"} = A} = DP <- Datapoints,
        not is_map_key('error.type', A)
    ],
    ?assertMatch(
        #{
            attributes := #{
                'db.system.name' := ~"postgresql",
                'db.namespace' := ~"metric_db",
                'db.query.summary' := ~"SELECT metric_events",
                'server.address' := ~"db.internal"
            },
            count := 1
        },
        Ok
    ),
    ?assertEqual(4, map_size(maps:get(attributes, Ok))),
    ?assert(abs(maps:get(sum, Ok) - 0.25) < 0.001),
    [Failed] = [A || #{attributes := #{'error.type' := ~"57014"} = A} <- Datapoints],
    ?assertEqual(~"57014", maps:get('db.response.status_code', Failed)),
    ok.

%% Helpers

metadata(Overrides) ->
    maps:merge(
        #{
            query => ~"SELECT * FROM users WHERE id = $1",
            params => [1],
            repo => my_repo,
            result => ok,
            num_rows => 1,
            source => ~"users",
            tenant => undefined,
            error_reason => undefined
        },
        Overrides
    ).

fire_event(Metadata) ->
    fire_event(Metadata, 1000).

fire_event(Metadata, Duration) ->
    telemetry:execute([kura, repo, query], #{duration => Duration, duration_us => 1}, Metadata).

receive_span() ->
    receive
        {span, #span{name = Name, kind = Kind, status = Status, attributes = Attributes}} ->
            {Name, Kind, span_status(Status), otel_attributes:map(Attributes)}
    after 5000 ->
        ct:fail(timeout_waiting_for_span)
    end.

span_status(#status{code = Code, message = Message}) -> {Code, Message};
span_status(undefined) -> undefined.

span_name({Name, _Kind, _Status, _Attributes}) -> Name.

span_attributes({_Name, _Kind, _Status, Attributes}) -> Attributes.

receive_datapoints(Name) ->
    receive
        {otel_histogram, Name, Datapoints} -> Datapoints
    after 5000 ->
        ct:fail({timeout_waiting_for_metric, Name})
    end.
