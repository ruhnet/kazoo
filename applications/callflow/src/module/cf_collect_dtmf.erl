%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2021, 2600Hz
%%% @doc Collect DTMF into an optional key for later retrieval.
%%%
%%% <h4>Data options:</h4>
%%% <dl>
%%%   <dt>`max_digits'</dt>
%%%   <dd>Maximum digits to collect. Default is to collect one digit.</dd>
%%%
%%%   <dt>`max_digits'</dt>
%%%   <dd>How long to wait for first DTMF, in milliseconds</dd>
%%%
%%%   <dt>`terminator'</dt>
%%%   <dd>What DTMF stops collection (and aren't included). Possible values are [0-9*#]. Default is `#'.</dd>
%%%
%%%   <dt>`terminators'</dt>
%%%   <dd>What DTMFs stops collection (and aren't included). Possible values are [0-9*#]. Default is `#'.</dd>
%%%
%%%   <dt>`interdigit_timeout'</dt>
%%%   <dd>How long to wait for the next DTMF, in milliseconds</dd>
%%%
%%%   <dt>`collection_name'</dt>
%%%   <dd>The name of the collection to store collected numbers for later processing</dd>
%%% </dl>
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_collect_dtmf).

-behaviour(gen_cf_action).

-include("callflow.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([handle/2]).

%%------------------------------------------------------------------------------
%% @doc Entry point for this module
%% @end
%%------------------------------------------------------------------------------
-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    kapps_call_command:answer(Call),

    AlreadyCollected =
        case kapps_call:get_dtmf_collection(Call) of
            'undefined' -> <<>>;
            <<_/binary>> = D -> D
        end,
    lager:debug("Already collected pre: ~p (~p)", [AlreadyCollected, terminators(Data)]),

    AlreadyCollected1 = list_to_binary(lists:filter(fun(T) -> lists:member(<<T>>, valid_digits(Data)) end
                                    ,binary_to_list(truncate_after_terminator(AlreadyCollected, terminators(Data)))
                                    )),
    lager:debug("Already collected: ~p (~s)", [AlreadyCollected1, collection_name(Data)]),
    maybe_collect_more_digits(Data, kapps_call:set_dtmf_collection('undefined', Call), AlreadyCollected1).

-spec maybe_collect_more_digits(kz_json:object(), kapps_call:call(), binary()) -> 'ok'.
maybe_collect_more_digits(Data, Call, AlreadyCollected) ->
    AlreadyCollectedSize = byte_size(AlreadyCollected),
    MaxDigits = max_digits(Data),
    maybe_collect_more_digits(Data, Call, AlreadyCollected, AlreadyCollectedSize, MaxDigits).

-spec maybe_collect_more_digits(kz_json:object(), kapps_call:call(), binary(), non_neg_integer(), pos_integer()) -> 'ok'.
maybe_collect_more_digits(Data, Call, AlreadyCollected, ACS, Max) when ACS >= Max ->
    lager:debug("early DTMF met collection criteria, not collecting any more digits"),
    <<Head:Max/binary, _/binary>> = AlreadyCollected,
    CollectionName = collection_name(Data),
    handle_digits(Call, Head, CollectionName);
maybe_collect_more_digits(Data, Call, AlreadyCollected, ACS, Max) ->
    collect_more_digits(Data, Call, AlreadyCollected, Max-ACS).

-spec collect_more_digits(kz_json:object(), kapps_call:call(), binary(), pos_integer()) -> 'ok'.
collect_more_digits(Data, Call, AlreadyCollected, MaxDigits) ->
    lager:debug("collecting more digits max(~p)", [MaxDigits]),
    CollectionName = collection_name(Data),
    case kapps_call_command:collect_digits(MaxDigits
                                          ,collect_timeout(Data)
                                          ,interdigit(Data)
                                          ,'undefined'
                                          ,terminators(Data)
                                          ,Call
                                          )
    of
        {'ok', Ds} ->
            case lists:member(Ds, valid_digits(Data)) of
                'true' ->
                    CollectedDigits = <<AlreadyCollected/binary, Ds/binary>>,
                    lager:debug("collected ~s for ~s", [CollectedDigits, CollectionName]),
                    handle_digits(Call, CollectedDigits, CollectionName);
                'false' ->
                    maybe_collect_more_digits(Data, Call, AlreadyCollected)
            end;
        {'error', _E} ->
            lager:debug("failed to collect DTMF: ~p", [_E]),
            handle_digits(Call, <<"timeout">>, CollectionName)
    end.

-spec handle_digits(kapps_call:call(), binary(), binary()) -> 'ok'.
handle_digits(Call, <<>>, CollectionName) ->
    handle_digits(Call, <<"timeout">>, CollectionName);
handle_digits(Call, CollectedDigits, CollectionName) ->
    case CollectedDigits of
        <<"timeout">> -> attempt_branch(Call, <<"timeout">>);
        <<"invalid">> -> attempt_branch(Call, <<"invalid">>);
        CollectedDigits ->
            UpdatedCall = kapps_call:set_dtmf_collection(CollectedDigits, CollectionName, Call),
            cf_exe:set_call(UpdatedCall),
            attempt_branch(UpdatedCall, CollectedDigits)
    end.

attempt_branch(Call, Branch) ->
    case cf_exe:attempt(Branch, Call) of
        {'attempt_resp', 'ok'} ->
            lager:info("selection is a callflow child"),
            'ok';
        {'attempt_resp', {'error', _}} when Branch =:= <<"invalid">> ->
            lager:info("no callflow child found for ~s", [Branch]),
            cf_exe:continue(Call);
        {'attempt_resp', {'error', _}} ->
            lager:info("invalid selection for ~s", [Branch]),
            attempt_branch(Call, <<"invalid">>)
    end.

-spec truncate_after_terminator(binary(), kz_term:ne_binaries()) -> binary().
truncate_after_terminator(AlreadyCollected, Terminators) ->
    hd(binary:split(AlreadyCollected, Terminators)).

-ifdef(TEST).
truncate_after_terminator_test_() ->
    [?_assertEqual(<<"1234">>, truncate_after_terminator(<<"1234#456#789">>, [<<"#">>, <<"*">>]))
    ,?_assertEqual(<<"1234">>, truncate_after_terminator(<<"1234">>, [<<"#">>]))
    ,?_assertEqual(<<"123">>, truncate_after_terminator(<<"123#">>, [<<"#">>, <<"*">>]))
    ,?_assertEqual(<<"1">>, truncate_after_terminator(<<"1*2#3">>, [<<"#">>, <<"*">>]))
    ,?_assertEqual(<<>>, truncate_after_terminator(<<"#234">>, [<<"#">>]))
    ].
-endif.

-spec collection_name(kz_json:object()) -> kz_term:ne_binary().
collection_name(Data) ->
    case kz_json:get_value(<<"collection_name">>, Data) of
        <<_/binary>> = Name -> Name;
        'undefined' -> <<"default">>
    end.

-spec max_digits(kz_json:object()) -> pos_integer().
max_digits(Data) ->
    case kz_json:get_integer_value(<<"max_digits">>, Data) of
        'undefined' -> 1;
        N when N > 0 -> N
    end.

-spec collect_timeout(kz_json:object()) -> pos_integer().
collect_timeout(Data) ->
    case kz_json:get_integer_value(<<"timeout">>, Data) of
        'undefined' -> 5000;
        N when N > 0 -> N
    end.

-spec interdigit(kz_json:object()) -> pos_integer().
interdigit(Data) ->
    case kz_json:get_integer_value(<<"interdigit_timeout">>, Data) of
        'undefined' -> kapps_call_command:default_interdigit_timeout();
        N when N > 0 -> N
    end.

-spec terminators(kz_json:object()) -> kz_term:ne_binaries().
terminators(Data) ->
    case kz_json:get_first_defined([<<"terminator">>, <<"terminators">>], Data) of
        'undefined' -> [<<"#">>];
        <<_/binary>> = T ->
            'true' = lists:member(T, ?ANY_DIGIT),
            [T];
        [_|_] = Ts ->
            'true' = lists:all(fun(T) -> lists:member(T, ?ANY_DIGIT) end, Ts),
            lists:usort(Ts)
    end.

-spec valid_digits(kz_json:object()) -> kz_term:ne_binaries().
    valid_digits(Data) ->
        case kz_json:get_value(<<"valid_digits">>, Data) of
            'undefined' -> ?ANY_DIGIT;
            <<_/binary>> = T ->
                'true' = lists:member(T, ?ANY_DIGIT),
                [T];
            [_|_] = Ts ->
                'true' = lists:all(fun(T) -> lists:member(T, ?ANY_DIGIT) end, Ts),
                lists:usort(Ts)
        end.
