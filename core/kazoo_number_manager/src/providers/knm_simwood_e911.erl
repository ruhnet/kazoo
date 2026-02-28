%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2014-2021, 2600Hz
%%% @doc Handle e911 provisioning
%%% @author James Aimonetti
%%% @author Peter Defebvre
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_simwood_e911).
-behaviour(knm_gen_provider).

-export([save/1]).
-export([delete/1]).

-include("knm.hrl").

-define(CUSTOMER_NAME, <<"customer_name">>).

-define(KNM_SW_CONFIG_CAT, <<(?KNM_CONFIG_CAT)/binary, ".simwood">>).

-define(SW_NUMBER_URL
       ,kapps_config:get_string(?KNM_SW_CONFIG_CAT
                               ,<<"numbers_api_url">>
                               ,<<"https://api.simwood.com/v3/numbers">>
                               )
       ).

-define(SW_ACCOUNT_ID, kapps_config:get_string(?KNM_SW_CONFIG_CAT, <<"simwood_account_id">>, <<>>)).
-define(SW_AUTH_USERNAME, kapps_config:get_binary(?KNM_SW_CONFIG_CAT, <<"auth_username">>, <<>>)).
-define(SW_AUTH_PASSWORD, kapps_config:get_binary(?KNM_SW_CONFIG_CAT, <<"auth_password">>, <<>>)).

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is saved, and will
%% provision e911 or remove the number depending on the state
%% @end
%%------------------------------------------------------------------------------

-spec save(knm_number:knm_number()) -> knm_number:knm_number().
save(Number) ->
    State = knm_phone_number:state(knm_number:phone_number(Number)),
    save(Number, State).

-spec save(knm_number:knm_number(), kz_term:ne_binary()) -> knm_number:knm_number().
save(Number, ?NUMBER_STATE_RESERVED) ->
    maybe_update_e911(Number);
save(Number, ?NUMBER_STATE_IN_SERVICE) ->
    maybe_update_e911(Number);
save(Number, ?NUMBER_STATE_PORT_IN) ->
    maybe_update_e911(Number);
save(Number, _State) ->
    delete(Number).

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is deleted, and will
%% provision e911 or remove the number depending on the state
%% @end
%%------------------------------------------------------------------------------
-spec delete(knm_number:knm_number()) -> knm_number:knm_number().
delete(Number) ->
    case feature(Number) of
        'undefined' -> Number;
        _Else ->
            lager:debug("removing e911 NoOp"),
            knm_providers:deactivate_feature(Number, ?FEATURE_E911)
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================


-spec query_simwood(kz_term:ne_binary(), 'get' | 'put' | 'delete', kz_json:object()) ->
          {'ok', iolist()} |
          {'error', 'not_available'}.
query_simwood(URL, Verb, JObj) ->
    lager:debug("Querying Simwood. Verb: ~p. URL: ~p.", [Verb, URL]),
    HTTPOptions = [{'ssl', [{'verify', 'verify_none'}]}
                  ,{'timeout', 180 * ?MILLISECONDS_IN_SECOND}
                  ,{'connect_timeout', 180 * ?MILLISECONDS_IN_SECOND}
                  ,{'basic_auth', {?SW_AUTH_USERNAME, ?SW_AUTH_PASSWORD}}
                  ],
    case kz_http:req(Verb, kz_term:to_binary(URL), [], JObj, HTTPOptions) of
        {'ok', 200, _RespHeaders, Body} ->
            lager:debug("Simwood success 200 (~s): ~p", [Body, _RespHeaders]),
            {'ok', Body};
        {'ok', _Resp, _RespHeaders, Body} ->
            lager:debug("Simwood response ~p ~p: ~p", [Body, _Resp, _RespHeaders]),
            {'error', Body};
        {'error', _R} ->
            lager:debug("Simwood response: ~p", [_R]),
            {'error', 'not_available'}
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec feature(knm_number:knm_number()) -> kz_json:api_json_term().
feature(Number) ->
    knm_phone_number:feature(knm_number:phone_number(Number), ?FEATURE_E911).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------

-spec maybe_update_e911(knm_number:knm_number()) -> knm_number:knm_number().
maybe_update_e911(Number) ->
    IsDryRun = knm_phone_number:dry_run(knm_number:phone_number(Number)),
    maybe_update_e911(Number, IsDryRun).

-spec maybe_update_e911(knm_number:knm_number(), boolean()) -> knm_number:knm_number().
maybe_update_e911(Number, 'true') ->
    CurrentE911 = feature(Number),
    E911 = kz_json:get_ne_value(?FEATURE_E911, knm_phone_number:doc(knm_number:phone_number(Number))),
    NotChanged = kz_json:are_equal(CurrentE911, E911),
    case kz_term:is_empty(E911) of
        'true' ->
            lager:debug("dry run: information has been removed, updating upstream"),
            knm_providers:deactivate_feature(Number, ?FEATURE_E911);
        'false' when NotChanged  ->
            Number;
        'false' ->
            lager:debug("dry run: information has been changed: ~s", [kz_json:encode(E911)]),
            knm_providers:activate_feature(Number, {?FEATURE_E911, E911})
    end;

maybe_update_e911(Number, 'false') ->
    CurrentE911 = feature(Number),
    E911 = kz_json:get_ne_value(?FEATURE_E911, knm_phone_number:doc(knm_number:phone_number(Number))),
    NotChanged = kz_json:are_equal(CurrentE911, E911),
    case kz_term:is_empty(E911) of
        'true' ->
            lager:debug("information has been removed, NoOp Upstream"),
            knm_providers:deactivate_feature(Number, ?FEATURE_E911);
        'false' when NotChanged  ->
            lager:debug("information notdd changed: ~s", [kz_json:encode(E911)]),
            Number;
        'false' ->
            lager:debug("information has been changed: ~s", [kz_json:encode(E911)]),
            case update_e911(Number, E911) of
                {'ok', _Data} ->
                    knm_providers:activate_feature(Number, {?FEATURE_E911, E911});
                {'error', E} ->
                    lager:error("information update failed: ~p", [E]),
                    knm_errors:invalid(Number, E)
            end
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec update_e911(knm_number:knm_number(), kz_json:object()) ->
          {'ok', kz_json:object() | kz_term:ne_binary()} |
          {'error', kz_term:ne_binary()}.
update_e911(Number, Address) ->
    Num = to_simwood(Number),
    URL = list_to_binary([?SW_NUMBER_URL, "/", ?SW_ACCOUNT_ID, <<"/allocated/">>, Num, <<"/999">>]),
    case query_simwood(URL, 'put', e911_address(Number, Address)) of
        {'ok', _R}=R -> R;
        {'error', _E}=E -> E
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec e911_address(knm_number:knm_number(), kz_json:object()) -> kz_json:object().
e911_address(_Number, JObj) ->
    kz_json:from_list(
      props:filter_empty(
        [{<<"title">>, kz_json:get_ne_binary_value(<<"title">>, JObj)}
        ,{<<"forename">>, kz_json:get_ne_binary_value(<<"forename">>, JObj)}
        ,{<<"name">>, kz_json:get_ne_binary_value(?E911_NAME, JObj)}
        ,{<<"premises">>, kz_json:get_ne_binary_value(?E911_STREET1, JObj)}
        ,{<<"thoroughfare">>, kz_json:get_ne_binary_value(?E911_STREET2, JObj)}
        ,{<<"locality">>, kz_json:get_ne_binary_value(?E911_CITY, JObj)}
        ,{<<"postcode">>, kz_json:get_ne_binary_value(?E911_ZIP, JObj)}
        ])).

-spec to_simwood(knm_number:knm_number()) -> kz_term:ne_binary().
to_simwood(Number) ->
    case knm_phone_number:number(knm_number:phone_number(Number)) of
        <<$+, N/binary>> -> N;
        N -> N
    end.