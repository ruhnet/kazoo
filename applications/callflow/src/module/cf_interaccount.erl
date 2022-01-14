%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2019, 2600Hz
%%% @doc
%%% @author Barnaby Puttick
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_interaccount).

-behaviour(gen_cf_action).

-include_lib("callflow/src/callflow.hrl").

-export([handle/2, lookup_account/1, presence_list/2]).

%%------------------------------------------------------------------------------
%% @doc Entry point for this moduleun, attempts to call an endpoint as defined
%% in the Data payload.  Returns continue if fails to connect or
%% stop when successful.
%% @end
%%------------------------------------------------------------------------------
-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    lager:debug("InterAccount Data: ~p", [Data]),
    ToUser = kapps_call:to_user(Call),
    FromRealm = kapps_call:from_realm(Call),
    FilterRealms = kz_json:get_list_value(<<"realms">>, Data, []),
    case lookup_account(ToUser, FromRealm, FilterRealms) of
        {'ok', AccountId, ToNumber} ->
            lager:debug("OK: ~s : ~s", [AccountId, ToNumber]),
            cf_resources:handle(request_data(AccountId), prepare_call(ToNumber, Data, Call));
        _ -> cf_exe:contiune(Call)
    end.

-spec request_data(kz_term:ne_binary()) -> kz_json:object().
request_data(AccountId) ->
    kz_json:from_list(
      [{<<"use_local_resources">>, false}
      ,{<<"caller_id_type">>, <<"internal">>}
      ,{<<"force_interaccount">>, AccountId}
      ]).


-spec prepare_call(kz_term:ne_binary(), kz_json:object(), kapps_call:call()) -> kapps_call:call().
prepare_call(ToNumber, Data, Call) -> 
                                                    Request = list_to_binary([ToNumber, "@", kapps_call:request_realm(Call)]),
                                                    To = list_to_binary([ToNumber, "@", kapps_call:to_realm(Call)]),
    PrefixName = kz_json:get_ne_binary_value(<<"caller_id_name_prefix">>, Data, <<>>),
    PrefixNumber = kz_json:get_ne_binary_value(<<"caller_id_number_prefix">>, Data, <<>>),

    lager:info("update prepend cid to <~s> ~s", [PrefixName, PrefixNumber]),
    Updates = [fun(C) -> kapps_call:kvs_store('prepend_cid_number', PrefixNumber, C) end
              ,fun(C) -> kapps_call:kvs_store('prepend_cid_name', PrefixName, C) end
						%,fun(C) -> kapps_call:set_callee_id_name(<<"Baboon">>, C) end
                                                ,fun(C) -> kapps_call:set_request(Request, C) end
                                                ,fun(C) -> kapps_call:set_to(To, C) end
                                                ,fun(C) -> kapps_call:set_callee_id_number(ToNumber, C) end
              ],
    Call1 = kapps_call:exec(Updates, Call),
    lager:info("BNP CALL updated from ~p to ~p", [Call, Call1]),
    cf_exe:set_call(Call1),
    Call1.

-spec lookup_account(kz_term:ne_binary()) -> any().
lookup_account(Number) -> lookup_account(Number, <<>>, []).

-spec lookup_account(kz_term:ne_binary(), kz_term:ne_binary(), list()) -> any().
lookup_account(Number, FromRealm, Realms) ->
    lager:debug("LOOKUP_ACCOUNT: ~s : ~s : ~p", [Number, FromRealm, Realms]),
    Keys = build_keys(Number, Realms),
    lager:debug("Search Keys: ~p", [Keys]),
    case 
        kz_datamgr:get_single_result(<<"accounts">>, 
                                     <<"accounts/listing_by_ia_prefix">>, 
                                     [{'keys', Keys}
                                     ,'first_when_multiple'
                                     ])
    of
        {'ok', JObj} ->
            AccountId = kz_json:get_value([<<"value">>, <<"account_id">>], JObj),
            Matches = kz_json:get_ne_value([<<"value">>, <<"matches">>], JObj, []),
            lager:debug("Found: ~p",[Matches]),
            case maybe_match_number(Matches, Number, FromRealm) of 
                'false' -> 
                    {'error', 'nomatch'};
                MatchedNumber ->
                    lager:debug("Processing number: ~s",[MatchedNumber]),
                    {'ok', AccountId, MatchedNumber}
            end;
        {'error', _R}=E ->
            lager:warning("unable to lookup interaccount number ~s: ~p", [Number, _R]),
            E
    end.

-spec build_keys(kz_term:ne_binary(), list()) -> [integer()].
build_keys(Number, [Realm|Realms]) ->
    case only_numeric(Number) of
        <<>> -> [];
        <<D:1/binary, Rest/binary>> ->
            build_keys(Rest, D, Realm, [kz_term:to_integer(D)])
                ++ build_keys(Number, Realms)
    end;
build_keys(_, []) -> [].

-spec build_keys(binary(), kz_term:ne_binary(), kz_term:ne_binary(), [list()]) -> list().
build_keys(<<D:1/binary, Rest/binary>>, Prefix, Realm, Acc) ->
    build_keys(Rest, <<Prefix/binary, D/binary>>, Realm, [[kz_term:to_integer(<<Prefix/binary, D/binary>>), Realm] | Acc]);
build_keys(<<>>, _, _, Acc) -> Acc.


-spec only_numeric(binary()) -> binary().
only_numeric(Number) ->
    << <<N>> || <<N>> <= Number, is_numeric(N)>>.

-spec is_numeric(integer()) -> boolean().
is_numeric(N) ->
    N >= $0
        andalso N =< $9.

-spec maybe_match_number(list(), kz_term:ne_binary(), kz_term:ne_binary()) -> kz_term:ne_binary().
maybe_match_number([], _Number, _AccRealm) ->
    lager:debug("No inter-account matches found for ~s from ~s",[_Number, _AccRealm]),
    'false';
maybe_match_number([Match|Matches], Number, FromRealm) ->
    MatchRegex = kz_json:get_ne_value(<<"regex">>, Match, <<>>),
    MatchRealms = kz_json:get_ne_value(<<"realms">>, Match, []),
    lager:debug("Found match regex: ~s for ~s : ~p", [MatchRegex, Number, MatchRealms]),
    case lists:member(FromRealm, MatchRealms) 
        andalso re:run(Number, MatchRegex, [{'capture', 'all', 'binary'}])
    of      
        'match' ->
            lager:debug("match for ~s -> ~s", [MatchRegex, Number]),
            Number;
        {'match', Captures} ->
            lager:debug("capturematch for ~s -> ~s (~p) (~p)", [MatchRegex, Number, Captures, lists:last(Captures)]),
            lists:last(Captures);
        _ ->
            lager:debug("nomatch for ~s -> ~s from ~s", [MatchRegex, Number, FromRealm]),
            maybe_match_number(Matches, Number, FromRealm)
    end.
maybe_match_numbers(_, [], _Realm) -> 'false';
maybe_match_numbers(Matches, [Number|Numbers], Realm) ->
    case maybe_match_number(Matches, Number, Realm) of
        'false' -> maybe_match_numbers(Matches, Numbers, Realm);
        Match -> Match
    end.



%%-spec set_number_props(kz_term:ne_binary(), kz_term:ne_binary()) -> any().
%%set_number_props(AccountId, Number) ->
%%      [{'pending_port', 'false'}
%%    ,{'local', 'false'}
%%    ,{'number', Number}
%%    ,{'account_id', AccountId}
%%    ,{'inbound_cnam', 'false'}
%%    ,{'force_outbound', 'false'}
%%    ].

-spec presence_list(kz_term:ne_binary(), kz_term:ne_binary()) -> list().    
presence_list(Username, Realm) ->
    AccountDoc = find_account_by_realm(Realm),
    lager:debug("Account Doc: ~p", [AccountDoc]),
    lager:debug("presence_list: ~p ~p", [Username, Realm]),
    Prefix = kz_json:get_value([<<"interaccount">>, <<"prefix">>], AccountDoc, <<>>),
    Matches = kz_json:get_value([<<"interaccount">>, <<"matches">>], AccountDoc, []),
    NumberList = [Username, <<Prefix/binary, Username/binary>>],
    MatchedNumber = maybe_match_numbers(Matches, NumberList, Realm),
    lager:debug("We have a matched number of ~p",[MatchedNumber]),
    case Prefix =/= 'undefined' andalso MatchedNumber =/= 'false' of
        'false' -> [];
        'true' -> build_presence_list(MatchedNumber, account_realms(), [])
    end.

build_presence_list(_, [], List) -> List;
build_presence_list(Username, [Realm|Realms], List) ->
    build_presence_list(Username, Realms, List ++ [{Username, Realm}]).

account_realms() ->
    case kz_datamgr:get_results( <<"accounts">>, <<"accounts/listing_by_realm">>, []) of
        {'ok', Accounts} -> [kz_json:get_value(<<"key">>, Account) || Account <- Accounts];
        _ -> []
    end.


-spec find_account_by_realm(kz_term:ne_binary()) -> any().
find_account_by_realm(Realm) ->
    case kapps_util:get_account_by_realm(Realm) of
        {'ok', AccountDb} -> 
            AccountId = kz_util:format_account_id(AccountDb, 'raw'), 
            {'ok', AccountDoc} = kz_datamgr:open_doc(AccountDb, AccountId),
            AccountDoc;
        _ -> 'undefined'
    end.
