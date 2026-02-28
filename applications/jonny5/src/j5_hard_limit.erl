%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2021, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(j5_hard_limit).

-export([authorize/2]).
-export([reconcile_cdr/2]).

-include("jonny5.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec authorize(j5_request:request(), j5_limits:limits()) -> j5_request:request().
authorize(Request, Limits) ->
    lager:debug("authorizing hard_limits"),
    case calls_at_limit(Limits)
        orelse resource_consumption_at_limit(Limits, Request)
        orelse owner_resource_consumption_at_limit(Limits, Request)
        orelse inbound_channels_per_did_at_limit(Request, Limits)
    of
        'true' -> j5_request:deny(<<"hard_limit">>, Request, Limits);
        'false' -> Request
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec reconcile_cdr(j5_request:request(), j5_limits:limits()) -> 'ok'.
reconcile_cdr(_, _) -> 'ok'.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec calls_at_limit(j5_limits:limits()) -> boolean().
calls_at_limit(Limits) ->
    Limit = j5_limits:calls(Limits),
    Used  = j5_channels:total_calls(j5_limits:account_id(Limits)),
    lager:debug("calls_limit ~p:~p",[Limit,Used]),
    should_deny(Limit, Used).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec resource_consumption_at_limit(j5_limits:limits(), j5_request:request()) -> boolean().
resource_consumption_at_limit(Limits, Request) ->
    AccountBilling = j5_request:account_billing(Request),
    Increment = case  AccountBilling =/= 'undefined' 
            andalso AccountBilling =/= <<"limits_disabled">> 
    of
        'true' -> 1;
	'false' -> 0
    end,
    Limit = j5_limits:resource_consuming_calls(Limits),
    Used  = j5_channels:resource_consuming(j5_limits:account_id(Limits)) + Increment,
    lager:debug("resource_consumption_limit ~p:~p (~p)",[Limit,Used,AccountBilling]),
    should_deny(Limit, Used).

-spec owner_resource_consumption_at_limit(j5_limits:limits(), j5_request:request()) -> boolean().
owner_resource_consumption_at_limit(Limits, Request) ->
    AccountBilling = j5_request:account_billing(Request),
    Increment = case  AccountBilling =/= 'undefined' 
            andalso AccountBilling =/= <<"limits_disabled">> 
    of
        'true' -> 1;
	'false' -> 0
    end,
    OwnerLimits = j5_limits:owner_limits(Limits),
    lager:debug("owner limits ~p", [OwnerLimits]),
    Limit = case kz_json:get_value(<<"resource_consuming_calls">>, OwnerLimits, 'undefined') of
	'undefined' -> -1;
	_Else -> _Else
    end,
    Used  = j5_channels:owner_resource_consuming(j5_limits:account_id(Limits), j5_request:owner_id(Request)) + Increment,
    lager:debug("owner resource_consumption_limit ~p:~p (~p)",[Limit,Used,AccountBilling]),
    should_deny(Limit, Used).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec inbound_channels_per_did_at_limit(kz_term:ne_binary(), j5_limits:limits()) -> boolean().
inbound_channels_per_did_at_limit(Request, Limits) ->
    AccountId = j5_limits:account_id(Limits),
    ToDID = j5_request:number(Request),
    PerDIDJObj = j5_limits:inbound_channels_per_did_rules(Limits),
    Limit = match_did_limits(ToDID, PerDIDJObj, kz_json:get_keys(PerDIDJObj)),
    Used  = j5_channels:total_inbound_channels_per_did_rules(ToDID, AccountId),
    lager:debug("inbound_channels_per_did_limit AccountId: ~p ToDid: ~p Used: ~p Limit: ~p"
               ,[AccountId ,ToDID ,Used ,Limit]
               ),
    should_deny(Limit, Used).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec should_deny(integer(), integer()) -> boolean().
should_deny(-1, _) -> false;
should_deny(0, _) -> 'true';
should_deny(Limit, Used) -> Used > Limit.

-spec match_did_limits(kz_term:ne_binary(), kz_json:object(), kz_json:keys()) -> integer().
match_did_limits(_ToDID, _PerDIDJObj, []) ->
    -1;
match_did_limits(ToDID, PerDIDJObj, [Key|Keys]) ->
    case re:run(ToDID, Key) of
        'nomatch' -> match_did_limits(ToDID, PerDIDJObj, Keys);
        _ ->  kz_json:get_integer_value(Key, PerDIDJObj)
    end.
