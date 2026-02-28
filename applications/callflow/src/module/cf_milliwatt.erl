%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2021, 2600Hz
%%% @doc
%%% @author Barnaby Puttick 2024
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_milliwatt).

-behaviour(gen_cf_action).

%% API
-include("callflow.hrl").
-export([handle/2]).
-define(DURATION, 10 * ?MILLISECONDS_IN_SECOND).

-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    Tone = get_tone(),
    DurationMS = get_duration_ms(Data),
    kapps_call_command:tones([Tone], Call),
    timer:sleep(DurationMS),
    cf_exe:continue(Call).

-spec get_duration_ms(kz_json:object()) -> non_neg_integer().
get_duration_ms(Data) ->
    Duration = kz_json:get_integer_value(<<"duration">>, Data, ?DURATION),
    Unit = kz_json:get_ne_binary_value(<<"unit">>, Data, <<"ms">>),
    duration_to_ms(Duration, Unit).

-spec duration_to_ms(integer(), kz_term:ne_binary()) -> non_neg_integer().
duration_to_ms(Duration, <<"ms">>) ->
    constrain_duration(Duration);
duration_to_ms(Duration, <<"s">>) ->
    constrain_duration(Duration * ?MILLISECONDS_IN_SECOND);
duration_to_ms(Duration, <<"m">>) ->
    constrain_duration(Duration * ?MILLISECONDS_IN_MINUTE);
duration_to_ms(Duration, <<"h">>) ->
    constrain_duration(Duration * ?MILLISECONDS_IN_HOUR);
duration_to_ms(Duration, _Unit) ->
    lager:debug("unknown unit: ~p", [_Unit]),
    duration_to_ms(Duration, <<"s">>).

-spec constrain_duration(integer()) -> integer().
constrain_duration(DurationMS) when DurationMS < 0 -> 0;
constrain_duration(DurationMS) when DurationMS > ?MILLISECONDS_IN_DAY ->
    ?MILLISECONDS_IN_DAY;
constrain_duration(DurationMS) ->
    DurationMS.

-spec get_tone() -> kz_json:object().
get_tone() ->
    Hz = [<<"1000">>],
    Duration = 30000,
    kz_json:from_list(
      [{<<"Frequencies">>, Hz}
      ,{<<"Duration-ON">>, kz_term:to_binary(Duration)}
      ,{<<"Duration-OFF">>, <<"1000">>}
      ]
     ).

