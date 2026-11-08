-module(opentelemetry_kura_tests).
-include_lib("eunit/include/eunit.hrl").

extract_operation_test() ->
    ?assertEqual(~"SELECT", opentelemetry_kura:extract_operation(~"SELECT * FROM users")),
    ?assertEqual(~"INSERT", opentelemetry_kura:extract_operation(~"INSERT INTO users")),
    ?assertEqual(~"UPDATE", opentelemetry_kura:extract_operation(~"UPDATE users SET")),
    ?assertEqual(~"DELETE", opentelemetry_kura:extract_operation(~"DELETE FROM users")),
    ?assertEqual(~"CREATE", opentelemetry_kura:extract_operation(~"CREATE TABLE users")),
    ?assertEqual(~"DROP", opentelemetry_kura:extract_operation(~"DROP TABLE users")),
    ?assertEqual(~"ALTER", opentelemetry_kura:extract_operation(~"ALTER TABLE users")),
    ?assertEqual(~"BEGIN", opentelemetry_kura:extract_operation(~"BEGIN")),
    ?assertEqual(~"COMMIT", opentelemetry_kura:extract_operation(~"COMMIT")),
    ?assertEqual(~"ROLLBACK", opentelemetry_kura:extract_operation(~"ROLLBACK")),
    ?assertEqual(~"OTHER", opentelemetry_kura:extract_operation(~"EXPLAIN SELECT 1")).

query_summary_test() ->
    ?assertEqual(~"SELECT users", opentelemetry_kura:query_summary(~"SELECT", ~"users")),
    ?assertEqual(~"INSERT posts", opentelemetry_kura:query_summary(~"INSERT", ~"posts")),
    ?assertEqual(~"BEGIN", opentelemetry_kura:query_summary(~"BEGIN", undefined)),
    ?assertEqual(undefined, opentelemetry_kura:query_summary(~"OTHER", ~"users")),
    ?assertEqual(undefined, opentelemetry_kura:query_summary(~"OTHER", undefined)).

span_name_test() ->
    Base = #{'db.system.name' => ~"postgresql"},
    ?assertEqual(
        ~"SELECT users",
        opentelemetry_kura:span_name(Base#{
            'db.query.summary' => ~"SELECT users", 'db.namespace' => ~"app"
        })
    ),
    ?assertEqual(
        ~"app|acme",
        opentelemetry_kura:span_name(Base#{
            'db.namespace' => ~"app|acme", 'server.address' => ~"db.local"
        })
    ),
    ?assertEqual(
        ~"db.local:6432",
        opentelemetry_kura:span_name(Base#{
            'server.address' => ~"db.local", 'server.port' => 6432
        })
    ),
    ?assertEqual(
        ~"db.local", opentelemetry_kura:span_name(Base#{'server.address' => ~"db.local"})
    ),
    ?assertEqual(~"postgresql", opentelemetry_kura:span_name(Base)).

namespace_test() ->
    ?assertEqual(~"app|acme", opentelemetry_kura:namespace(~"app", ~"acme")),
    ?assertEqual(~"acme", opentelemetry_kura:namespace(undefined, ~"acme")).

error_attributes_test() ->
    ?assertEqual(#{}, opentelemetry_kura:error_attributes(ok, undefined)),
    ?assertEqual(
        #{'error.type' => ~"23505", 'db.response.status_code' => ~"23505"},
        opentelemetry_kura:error_attributes(
            error, {pgsql_error, #{code => ~"23505", constraint => ~"users_name_key"}}
        )
    ),
    ?assertEqual(
        #{'error.type' => ~"timeout"}, opentelemetry_kura:error_attributes(error, timeout)
    ),
    ?assertEqual(
        #{'error.type' => ~"unique_violation"},
        opentelemetry_kura:error_attributes(error, {unique_violation, ~"users_name_key"})
    ),
    ?assertEqual(
        #{'error.type' => ~"_OTHER"}, opentelemetry_kura:error_attributes(error, undefined)
    ),
    ?assertEqual(#{'error.type' => ~"_OTHER"}, opentelemetry_kura:error_attributes(error, "boom")).

stability_mode_test() ->
    ?assertEqual(stable, opentelemetry_kura:stability_mode(false)),
    ?assertEqual(stable, opentelemetry_kura:stability_mode("")),
    ?assertEqual(stable, opentelemetry_kura:stability_mode("database")),
    ?assertEqual(stable, opentelemetry_kura:stability_mode("http/dup")),
    ?assertEqual(dup, opentelemetry_kura:stability_mode("database/dup")),
    ?assertEqual(dup, opentelemetry_kura:stability_mode("http, database/dup")),
    ?assertEqual(dup, opentelemetry_kura:stability_mode("database,database/dup")).

format_value_test() ->
    ?assertEqual(~"hello", opentelemetry_kura:format_value(~"hello")),
    ?assertEqual(~"world", opentelemetry_kura:format_value(world)),
    ?assertEqual(~"42", opentelemetry_kura:format_value(42)),
    ?assertEqual(~"[1,2,3]", opentelemetry_kura:format_value([1, 2, 3])),
    ?assertEqual(~"{a,<<\"é\"/utf8>>}", opentelemetry_kura:format_value({a, ~"é"})),
    Long = binary:copy(~"x", 10000),
    Deep = nested(1000),
    [
        ?assert(byte_size(opentelemetry_kura:format_value(Value)) =< 160)
     || Value <- [Long, lists:seq(1, 10000), Deep, 1 bsl 4096, #{K => K || K <- lists:seq(1, 500)}]
    ].

sanitize_query_test() ->
    Query = ~"SELECT * FROM users WHERE id = $1",
    ?assertEqual(Query, opentelemetry_kura:sanitize_query(Query, #{})),
    ?assertEqual(
        ~"[SANITIZED]", opentelemetry_kura:sanitize_query(Query, #{sanitize_query => true})
    ),
    Fun = fun(Q) -> <<"REDACTED: ", Q/binary>> end,
    ?assertEqual(
        ~"REDACTED: SELECT * FROM users WHERE id = $1",
        opentelemetry_kura:sanitize_query(Query, #{sanitize_query => Fun})
    ).

invalid_repos_test() ->
    [
        ?assertError({invalid_repos, Repos}, opentelemetry_kura:setup(#{repos => Repos}))
     || Repos <- [
            [my_repo],
            #{"my_repo" => #{}},
            #{my_repo => [{namespace, ~"db"}]},
            #{my_repo => #{namespace => "db"}},
            #{my_repo => #{server_port => 0}},
            #{my_repo => #{server_port => 70000}},
            #{my_repo => #{system => postgresql}},
            #{my_repo => #{password => ~"secret"}}
        ]
    ].

nested(0) -> [];
nested(Depth) -> [nested(Depth - 1)].
