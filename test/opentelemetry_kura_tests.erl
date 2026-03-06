-module(opentelemetry_kura_tests).
-include_lib("eunit/include/eunit.hrl").

extract_operation_test() ->
    ?assertEqual(<<"SELECT">>, opentelemetry_kura:extract_operation(<<"SELECT * FROM users">>)),
    ?assertEqual(<<"INSERT">>, opentelemetry_kura:extract_operation(<<"INSERT INTO users">>)),
    ?assertEqual(<<"UPDATE">>, opentelemetry_kura:extract_operation(<<"UPDATE users SET">>)),
    ?assertEqual(<<"DELETE">>, opentelemetry_kura:extract_operation(<<"DELETE FROM users">>)),
    ?assertEqual(<<"CREATE">>, opentelemetry_kura:extract_operation(<<"CREATE TABLE users">>)),
    ?assertEqual(<<"DROP">>, opentelemetry_kura:extract_operation(<<"DROP TABLE users">>)),
    ?assertEqual(<<"ALTER">>, opentelemetry_kura:extract_operation(<<"ALTER TABLE users">>)),
    ?assertEqual(<<"BEGIN">>, opentelemetry_kura:extract_operation(<<"BEGIN">>)),
    ?assertEqual(<<"COMMIT">>, opentelemetry_kura:extract_operation(<<"COMMIT">>)),
    ?assertEqual(<<"ROLLBACK">>, opentelemetry_kura:extract_operation(<<"ROLLBACK">>)),
    ?assertEqual(<<"OTHER">>, opentelemetry_kura:extract_operation(<<"EXPLAIN SELECT 1">>)).

span_name_test() ->
    ?assertEqual(<<"SELECT users">>, opentelemetry_kura:span_name(<<"SELECT">>, <<"users">>)),
    ?assertEqual(<<"INSERT posts">>, opentelemetry_kura:span_name(<<"INSERT">>, <<"posts">>)),
    ?assertEqual(<<"SELECT">>, opentelemetry_kura:span_name(<<"SELECT">>, undefined)).

maybe_add_source_test() ->
    Base = #{'db.system' => <<"postgresql">>},
    ?assertEqual(
        Base#{'db.collection.name' => <<"users">>},
        opentelemetry_kura:maybe_add_source(Base, <<"users">>)
    ),
    ?assertEqual(Base, opentelemetry_kura:maybe_add_source(Base, undefined)).
