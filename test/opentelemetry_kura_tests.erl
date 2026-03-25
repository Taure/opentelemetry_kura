-module(opentelemetry_kura_tests).
-include_lib("eunit/include/eunit.hrl").

-eqwalizer({nowarn_function, maybe_set_error_test/0}).

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

span_name_test() ->
    ?assertEqual(~"SELECT users", opentelemetry_kura:span_name(~"SELECT", ~"users")),
    ?assertEqual(~"INSERT posts", opentelemetry_kura:span_name(~"INSERT", ~"posts")),
    ?assertEqual(~"SELECT", opentelemetry_kura:span_name(~"SELECT", undefined)).

maybe_add_source_test() ->
    Base = #{'db.system' => ~"postgresql"},
    ?assertEqual(
        Base#{'db.collection.name' => ~"users"},
        opentelemetry_kura:maybe_add_source(Base, ~"users")
    ),
    ?assertEqual(Base, opentelemetry_kura:maybe_add_source(Base, undefined)).

maybe_add_tenant_test() ->
    Base = #{'db.system' => ~"postgresql"},
    ?assertEqual(Base, opentelemetry_kura:maybe_add_tenant(Base, undefined)),
    ?assertEqual(
        Base#{'db.kura.tenant' => ~"acme"},
        opentelemetry_kura:maybe_add_tenant(Base, {prefix, ~"acme"})
    ),
    ?assertEqual(
        Base#{'db.kura.tenant' => ~"org_id:42"},
        opentelemetry_kura:maybe_add_tenant(Base, {attribute, {org_id, 42}})
    ),
    ?assertEqual(
        Base#{'db.kura.tenant' => ~"region:eu-west"},
        opentelemetry_kura:maybe_add_tenant(Base, {attribute, {region, ~"eu-west"}})
    ).

format_value_test() ->
    ?assertEqual(~"hello", opentelemetry_kura:format_value(~"hello")),
    ?assertEqual(~"world", opentelemetry_kura:format_value(world)),
    ?assertEqual(~"42", opentelemetry_kura:format_value(42)),
    ?assertEqual(~"[1,2,3]", opentelemetry_kura:format_value([1, 2, 3])).

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

maybe_set_error_test() ->
    ?assertEqual(ok, opentelemetry_kura:maybe_set_error(undefined, ok, undefined)),
    ?assertEqual(ok, opentelemetry_kura:maybe_set_error(undefined, ok, some_reason)).
