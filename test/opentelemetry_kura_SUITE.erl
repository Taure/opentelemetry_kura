-module(opentelemetry_kura_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-eqwalizer({nowarn_function, basic_query/1}).
-eqwalizer({nowarn_function, query_with_tenant/1}).
-eqwalizer({nowarn_function, sanitized_query/1}).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    basic_query/1,
    query_with_tenant/1,
    query_error/1,
    sanitized_query/1
]).

all() ->
    [basic_query, query_with_tenant, query_error, sanitized_query].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    application:load(opentelemetry),
    application:set_env(opentelemetry, traces_exporter, none),
    application:set_env(opentelemetry, processors, [
        {otel_simple_processor, #{}}
    ]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    Config.

end_per_suite(_Config) ->
    application:stop(opentelemetry),
    ok.

init_per_testcase(_TestCase, Config) ->
    otel_simple_processor:set_exporter(otel_exporter_pid, self()),
    Config.

end_per_testcase(_TestCase, _Config) ->
    telemetry:detach(~"opentelemetry-kura-query"),
    ok.

basic_query(Config) ->
    opentelemetry_kura:setup(),
    fire_event(#{
        query => ~"SELECT * FROM users WHERE id = $1",
        params => [1],
        repo => my_repo,
        result => ok,
        num_rows => 1,
        source => ~"users",
        tenant => undefined,
        error_reason => undefined
    }),
    Span = receive_span(Config),
    ?assertEqual(~"SELECT users", Span#span.name),
    ?assertEqual(?SPAN_KIND_CLIENT, Span#span.kind),
    Attrs = otel_attributes:map(Span#span.attributes),
    ?assertEqual(~"postgresql", maps:get('db.system', Attrs)),
    ?assertEqual(~"SELECT * FROM users WHERE id = $1", maps:get('db.statement', Attrs)),
    ?assertEqual(~"SELECT", maps:get('db.operation', Attrs)),
    ?assertEqual(~"my_repo", maps:get('db.kura.repo', Attrs)),
    ?assertEqual(1, maps:get('db.kura.num_rows', Attrs)),
    ?assertEqual(~"users", maps:get('db.collection.name', Attrs)),
    ?assertEqual(1, maps:get('db.query.parameter_count', Attrs)),
    ?assertNot(maps:is_key('db.kura.tenant', Attrs)),
    ?assertEqual(undefined, Span#span.status),
    ok.

query_with_tenant(Config) ->
    opentelemetry_kura:setup(),
    fire_event(#{
        query => ~"SELECT * FROM users",
        params => [],
        repo => my_repo,
        result => ok,
        num_rows => 5,
        source => ~"users",
        tenant => {prefix, ~"acme"},
        error_reason => undefined
    }),
    Span = receive_span(Config),
    Attrs = otel_attributes:map(Span#span.attributes),
    ?assertEqual(~"acme", maps:get('db.kura.tenant', Attrs)),

    telemetry:detach(~"opentelemetry-kura-query"),
    opentelemetry_kura:setup(),
    fire_event(#{
        query => ~"SELECT * FROM users",
        params => [],
        repo => my_repo,
        result => ok,
        num_rows => 3,
        source => ~"users",
        tenant => {attribute, {org_id, 42}},
        error_reason => undefined
    }),
    Span2 = receive_span(Config),
    Attrs2 = otel_attributes:map(Span2#span.attributes),
    ?assertEqual(~"org_id:42", maps:get('db.kura.tenant', Attrs2)),
    ok.

query_error(Config) ->
    opentelemetry_kura:setup(),
    fire_event(#{
        query => ~"INSERT INTO users (name) VALUES ($1)",
        params => [~"test"],
        repo => my_repo,
        result => error,
        num_rows => 0,
        source => ~"users",
        tenant => undefined,
        error_reason => {unique_violation, ~"users_name_key"}
    }),
    Span = receive_span(Config),
    ?assertMatch({status, error, _}, Span#span.status),
    {status, error, Msg} = Span#span.status,
    ?assertNotEqual(~"query failed", Msg),
    ok.

sanitized_query(Config) ->
    opentelemetry_kura:setup(#{sanitize_query => true}),
    fire_event(#{
        query => ~"SELECT secret FROM passwords",
        params => [],
        repo => my_repo,
        result => ok,
        num_rows => 0,
        source => ~"passwords",
        tenant => undefined,
        error_reason => undefined
    }),
    Span = receive_span(Config),
    Attrs = otel_attributes:map(Span#span.attributes),
    ?assertEqual(~"[SANITIZED]", maps:get('db.statement', Attrs)),
    ok.

%% Helpers

fire_event(Metadata) ->
    telemetry:execute(
        [kura, repo, query],
        #{duration => 1000, duration_us => 1},
        Metadata
    ).

receive_span(_Config) ->
    receive
        {span, Span} -> Span
    after 5000 ->
        ct:fail(timeout_waiting_for_span)
    end.
