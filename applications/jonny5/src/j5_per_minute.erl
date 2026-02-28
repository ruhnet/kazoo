%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2021, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(j5_per_minute).

-export([authorize/2]).
-export([reconcile_cdr/2]).
-export([maybe_credit_available/1
         ,maybe_credit_available/2
        ]).
-export([maybe_user_credit_available/2]).
-include("jonny5.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec authorize(j5_request:request(), j5_limits:limits()) -> j5_request:request().
authorize(Request, Limits) ->
    IsReseller =  j5_request:is_reseller_billing(Request, Limits),
    AccountId = j5_limits:account_id(Limits),
    CreditAvailable = case IsReseller of
        'true' ->
            lager:info("checking if reseller ~s has available per-minute credit"
                       ,[AccountId]
                       ),
            maybe_credit_available(Limits);
        'false' ->
            lager:info("checking if account ~s has available per-minute credit"
               ,[AccountId]
               ),
            OwnerId = j5_request:owner_id(Request),
            maybe_credit_available(Limits, OwnerId)
    end,
    case CreditAvailable of
        'false' -> Request;
        'true' -> j5_request:authorize(<<"per_minute">>, Request, Limits)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec reconcile_cdr(j5_request:request(), j5_limits:limits()) -> 'ok'.
reconcile_cdr(Request, Limits) ->
    case j5_request:billing(Request, Limits) of
        <<"per_minute">> -> reconcile_call_cost(Request, Limits);
        _Else -> 'ok'
    end.

-spec reconcile_call_cost(j5_request:request(), j5_limits:limits()) -> 'ok'.
reconcile_call_cost(Request, Limits) ->
    ReconcileZero = kapps_config:get_is_true(?APP_NAME, <<"reconcile_zero_call_costs">>, 'false'),
    IsReseller =  j5_request:is_reseller_billing(Request, Limits),
    lager:info("call cost limits: ~p ~p", [IsReseller, Limits]),
    case j5_request:calculate_call(Request, IsReseller) of
        {0, 0} -> 'ok';
        {_, 0} when not ReconcileZero -> 'ok';
        {Seconds, Amount} ->
            create_ledger_usage(Seconds, Amount, Request, Limits)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec maybe_credit_available(j5_limits:limits()) -> boolean().
maybe_credit_available(Limits) -> maybe_credit_available(Limits, 'undefined').

-spec maybe_credit_available(j5_limits:limits(), kz_term:ne_binary() | 'undefined') -> boolean().
maybe_credit_available(Limits, OwnerId) ->
    AccountId = j5_limits:account_id(Limits),
    PerMinuteCost = j5_channels:per_minute_cost(AccountId),
    AvailableAccountUnits = kz_currency:available_units(AccountId, 0) - PerMinuteCost,
    ReserveUnits = j5_limits:reserve_amount(Limits),
    AccountBalance = AvailableAccountUnits - PerMinuteCost,
    (maybe_prepay_credit_available(AccountBalance, ReserveUnits, Limits)
        orelse maybe_postpay_credit_available(AccountBalance, ReserveUnits, Limits))
        andalso maybe_user_credit_available(AccountId, OwnerId).

-spec maybe_prepay_credit_available(kz_currency:units(), kz_currency:units(), j5_limits:limits()) -> boolean().
maybe_prepay_credit_available(AvailableUnits, ReserveUnits, Limits) ->
    AccountId = j5_limits:account_id(Limits),
    Dbg = [AccountId
          ,kz_currency:units_to_dollars(ReserveUnits)
          ,kz_currency:units_to_dollars(AvailableUnits)
          ],
    case j5_limits:allow_prepay(Limits) of
        'false' ->
            lager:info("account ~s is restricted from using prepay", [AccountId]),
            'false';
        'true' when (AvailableUnits - ReserveUnits) > 0 ->
            lager:info("using prepay from account ~s £~w/£~w", Dbg),
            'true';
        'true' ->
            lager:info("account ~s does not have enough prepay credit £~w/£~w", Dbg),
            'false'
    end.


-spec maybe_postpay_credit_available(kz_currency:units(), kz_currency:units(), j5_limits:limits()) -> boolean().
maybe_postpay_credit_available(AvailableUnits, ReserveUnits, Limits) ->
    AccountId = j5_limits:account_id(Limits),
    MaxPostpay = j5_limits:max_postpay(Limits),
    case j5_limits:allow_postpay(Limits) of
        'false' ->
            lager:info("account ~s is restricted from using postpay"
                       ,[AccountId]
                       ),
            'false';
        'true' when (AvailableUnits - ReserveUnits) > MaxPostpay ->
            lager:info("using postpay from account ~s £~w/£~w/£~w"
                       ,[AccountId
                        ,kz_currency:units_to_dollars(ReserveUnits)
                        ,kz_currency:units_to_dollars(AvailableUnits)
                        ,kz_currency:units_to_dollars(MaxPostpay)
                        ]
                       ),
            'true';
        'true' ->
            lager:info("account ~s would exceed the maximum postpay amount £~w/£~w"
                       ,[AccountId
                        ,kz_currency:units_to_dollars(AvailableUnits)
                        ,kz_currency:units_to_dollars(MaxPostpay)
                        ]
                       ),
            'false'
    end.

-spec maybe_user_credit_available(kz_term:ne_binary(), kz_term:ne_binary() | 'undefined') -> boolean().
maybe_user_credit_available(AccountId, 'undefined') ->
    lager:debug("account ~s has no associated owner for this channel", [AccountId]),
    'true';
maybe_user_credit_available(AccountId, <<OwnerId/binary>>) ->
    case kzd_users:fetch(AccountId, OwnerId) of
        {'ok', UserDoc} -> maybe_user_credit_available(AccountId, OwnerId, UserDoc);
        {'error', _R} ->
            lager:warning("find owner ~p for account ~p failed: ~p", [OwnerId, AccountId, _R]),
            'true'
    end.
-spec maybe_user_credit_available(kz_term:ne_binary(), kz_term:ne_binary(), kzd_users:doc()) -> boolean().
maybe_user_credit_available(AccountId, OwnerId, OwnerDoc) ->
    case kzd_users:userpay_enabled(OwnerDoc) of
        'false' ->
            lager:info("owner ~s isn't using userpay", [OwnerId]),
            'true';
        'true' ->
            lager:info("owner ~s is using userpay", [OwnerId]),
            AvailableUnits = kz_currency:available_units(AccountId, OwnerId, 0),
            PerMinuteCost = j5_channels:per_minute_cost(AccountId, OwnerId),
            UserBalance = AvailableUnits - PerMinuteCost,
            MaxUserPay = kzd_users:userpay_limit(OwnerDoc) *-1,
            Dbg = [OwnerId
                  ,kz_currency:units_to_dollars(AvailableUnits)
                  ,kz_currency:units_to_dollars(PerMinuteCost)
                  ,kz_currency:units_to_dollars(UserBalance)
                  ,kz_currency:units_to_dollars(MaxUserPay)
                  ],
            case UserBalance > MaxUserPay of
                'true' ->
                    lager:info("owner ~s is within their credit limit: - (£~w - £~w) = £~w > £~w", Dbg),
                    'true';
                'false' ->
                    lager:info("owner ~s is NOT within their credit limit: - (£~w - £~w) = £~w > £~w", Dbg),
                    'false'
            end
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec create_ledger_usage(kz_currency:units(), kz_currency:units(), j5_request:request(), j5_limits:limits()) -> any().
create_ledger_usage(Seconds, Amount, Request, Limits) ->
    Setters =
        props:filter_empty(
          [{fun kz_ledger:set_account/2, j5_request:account_id(Request)}
          ,{fun kz_ledger:set_source_service/2, <<"per-minute-voip">>}
          ,{fun kz_ledger:set_source_id/2, j5_request:call_id(Request)}
          ,{fun kz_ledger:set_description/2, j5_request:rate_name(Request)}
          ,{fun kz_ledger:set_usage_type/2, <<"voice">>}
          ,{fun kz_ledger:set_usage_quantity/2, Seconds}
          ,{fun kz_ledger:set_usage_unit/2, <<"sec">>}
          ,{fun kz_ledger:set_period_start/2, j5_request:timestamp(Request)}
          ,{fun kz_ledger:set_metadata/2, metadata(Request)}
          ,{fun kz_ledger:set_unit_amount/2, Amount}
          ]
         ),
    kz_ledger:debit(kz_ledger:setters(Setters), j5_limits:account_id(Limits)).

-spec metadata(j5_request:request()) -> kz_json:object().
metadata(Request) ->
    RateObj = kz_json:from_list(
                [{<<"name">>, j5_request:rate_name(Request)}
                ,{<<"description">>, j5_request:rate_description(Request)}
                ,{<<"value">>, j5_request:rate(Request)}
                ,{<<"increment">>, j5_request:rate_increment(Request)}
                ,{<<"minimum">>, j5_request:rate_minimum(Request)}
                ,{<<"nocharge_time">>, j5_request:rate_nocharge_time(Request)}
                ]),
    kz_json:from_list(
      [{<<"to">>, j5_request:to(Request)}
      ,{<<"from">>, j5_request:from(Request)}
      ,{<<"direction">>, j5_request:call_direction(Request)}
      ,{<<"caller_id_number">>, j5_request:caller_id_number(Request)}
      ,{<<"caller_id_name">>, j5_request:caller_id_name(Request)}
      ,{<<"callee_id_number">>, j5_request:callee_id_number(Request)}
      ,{<<"callee_id_name">>, j5_request:callee_id_name(Request)}
      ,{<<"resource_type">>, j5_request:resource_type(Request)}
      ,{<<"account_trunk_usage">>, j5_request:account_trunk_usage(Request)}
      ,{<<"reseller_trunk_usage">>, j5_request:reseller_trunk_usage(Request)}
      ,{<<"classification">>, j5_request:classification(Request)}
      ,{<<"owner_id">>, j5_request:owner_id(Request)}
      ,{<<"rate">>, RateObj}
      ,{<<"billing_seconds">>, j5_request:billing_seconds(Request)}
      ]).
