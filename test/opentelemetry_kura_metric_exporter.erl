-module(opentelemetry_kura_metric_exporter).

-export([init/1, export/3, shutdown/1]).

init(_) ->
    {ok, []}.

export(Metrics, _Resource, _State) ->
    case persistent_term:get(opentelemetry_kura_metric_pid, undefined) of
        Pid when is_pid(Pid) ->
            [Pid ! {otel_histogram, Name, Datapoints} || {Name, Datapoints} <- histograms(Metrics)];
        _ ->
            ok
    end,
    ok.

shutdown(_) ->
    ok.

%% Destructures the metric, histogram and histogram_datapoint records of
%% opentelemetry_experimental's otel_metrics.hrl as tuples: eqwalizer rejects
%% that header's record definitions, so it cannot be included here.
histograms(Metrics) ->
    [
        {Name, [
            #{attributes => Attributes, count => Count, sum => Sum}
         || {histogram_datapoint, Attributes, _Start, _Time, Count, Sum, _Buckets, _Bounds,
                _Exemplars, _Flags, _Min, _Max} <- Datapoints
        ]}
     || {metric, Name, _Scope, _Description, _Unit, {histogram, Datapoints, _Temporality}} <-
            Metrics
    ].
