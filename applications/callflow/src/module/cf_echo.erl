%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2021, 2600Hz
%%% @doc
%%% @author Barnaby Puttick 2024
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_echo).

-behaviour(gen_cf_action).

%% API
-include("callflow.hrl").
-export([handle/2, get_duration_ms/1]).
-define(DURATION, 10 * ?MILLISECONDS_IN_SECOND).

-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(_Data, Call) ->
    kapps_call_command:answer(Call),

    Command = kz_json:from_list(
        [{<<"Application-Name">>, <<"echo">>}
        ,{<<"Terminators">>, [<<"#">>]}
        ,{<<"Call-ID">>, kapps_call:call_id(Call)}
    ]),
    send_command(Command, Call).

send_command(ECommand, Call) ->
    NoopId = kz_datamgr:get_uuid(),

    Commands = [kz_json:from_list([{<<"Application-Name">>, <<"noop">>}
                                  ,{<<"Call-ID">>, kapps_call:call_id(Call)}
                                  ,{<<"Msg-ID">>, NoopId}
                                  ])
               ,ECommand
               ],
    Command = [{<<"Application-Name">>, <<"queue">>}
              ,{<<"Commands">>, Commands}
              ],
    kapps_call_command:send_command(Command, Call),

    lager:debug("echo is waiting for noop ~s", [NoopId]),
    case cf_util:wait_for_noop(Call, NoopId) of
        {'ok', Call1} ->
            lager:debug("echo got noop ~s", [NoopId]),

            %% Give control back to cf_exe process
            cf_exe:set_call(Call1),
            cf_exe:continue(Call1);
        {'error', _} ->
            cf_exe:stop(Call)
    end.


%handle(Data, Call) ->
%    DurationMS = get_duration_ms(Data),
%    kapps_call_command:set_terminators([<<"#">>], Call),
%    kapps_call_command:echo(Call),
%    timer:sleep(DurationMS),
%    kapps_call_command:queued_hangup(Call),
%    cf_exe:hard_stop(Call).

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

