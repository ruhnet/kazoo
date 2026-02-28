%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2021, 2600Hz
%%% @doc
%%% @author Kirill Sysoev
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_route_to_user).

-behaviour(gen_cf_action).

-include("callflow.hrl").

-export([handle/2]).

-define(DEFAULT_VM_ANSWER_TIMEOUT_S, 20).
-define(DEFAULT_RING_TIMEOUT_S, 30).

%%------------------------------------------------------------------------------
%% @doc This module attempts to lookup endpoints by it's cid number.
%% Returns continue if fails to connect or stop when successful.
%% @end
%%------------------------------------------------------------------------------
-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    lager:debug("CALL: ~p", [Call]),
    FromNumber = get_caller_number(Call),
    lager:info("received call from: ~s", [FromNumber]),
    CCVs = kapps_call:custom_channel_vars(Call),
    case kapps_call:owner_id(Call) =:= 'undefined'
            orelse kz_json:is_true(<<"Retain-CID">>, CCVs)
    of
        'true' -> prepare_to_route(FromNumber, Data, Call);
        'false' -> validate_account_number(FromNumber, Data, Call)
    end.

get_caller_number(Call) ->
      knm_converters:normalize(kapps_call:caller_id_number(Call)).

validate_account_number(FromNumber, Data, Call) ->
    AccountDb = kapps_call:account_db(Call),
    OwnerId = kapps_call:owner_id(Call),
    lager:debug("validating external number <~s> for user: ~s", [FromNumber, OwnerId]),
    case number_lookup(AccountDb, OwnerId, FromNumber) of
        'undefined' ->
            lager:debug("external number could not be validated (~s), bailing..", [FromNumber]),
            cf_exe:continue(Call);
       ValidNumber ->
            prepare_to_route(ValidNumber, Data, Call, OwnerId)
   end.

prepare_to_route(ValidNumber, Data, Call) ->
    prepare_to_route(ValidNumber, Data, Call, 'undefined').

prepare_to_route(ValidNumber, Data, Call, OwnerId) ->
    ValidName = formatNumberToName(ValidNumber),
    CCVs = kapps_call:custom_channel_vars(Call),
    lager:debug("CCVs: ~p", [CCVs]),

    Props = props:filter_undefined(
       [{<<"Caller-ID-Name">>, ValidName}
       ,{<<"Caller-ID-Number">>, ValidNumber}
       ,{<<"Caller-Owner-ID">>, OwnerId}
       | get_privacy_flags(Call, OwnerId) ++ get_resource_props(CCVs, OwnerId)
       ]),
    Updates = [fun(C) -> kapps_call:kvs_store('rewrite_cid_name', ValidName, C) end
             ,fun(C) -> kapps_call:kvs_store('rewrite_cid_number', ValidNumber, C) end
             ,fun(C) -> kapps_call:set_caller_id_name(ValidName, C) end
             ,fun(C) -> kapps_call:set_caller_id_number(ValidNumber, C) end
             ,fun(C) -> kapps_call:set_custom_channel_vars(Props, C) end
             ],
    lager:info("validated caller id: \"~s\" <~s> -- ~p", [ValidName, ValidNumber, get_privacy_flags(Call, OwnerId) ++ get_resource_props(CCVs, OwnerId)]),
    UpdatedCall = kapps_call:exec(Updates, Call),
    cf_exe:set_call(UpdatedCall),
    route_call(Data, UpdatedCall).

get_resource_props(CCVs, 'undefined') ->
    [{<<"Resource-ID">>, kz_json:get_value(<<"Resource-ID">>, CCVs, <<"c6aa2588a5a9a0ceb0f662615bcda4e3">>)}
    ,{<<"Resource-Type">>, kz_json:get_value(<<"Resource-Type">>, CCVs, <<"offnet-origination">>)}
    ,{<<"Authorizing-Type">>, kz_json:get_value(<<"Authorizing-Type">>, CCVs, <<"resource">>)}
    ,{<<"Global-Resource">>, 'true'}
    ];
get_resource_props(CCVs, OwnerId) ->
    [{<<"Resource-ID">>, kz_json:get_value(<<"Resource-ID">>, CCVs, OwnerId)}
    ,{<<"Resource-Type">>, kz_json:get_value(<<"Resource-Type">>, CCVs, <<"onnet-origination">>)}
    ,{<<"Authorizing-Type">>, kz_json:get_value(<<"Authorizing-Type">>, CCVs, <<"user">>)}
    ].

get_privacy_flags(Call, UserId) ->
    UseEndpoint =  kapps_call:kvs_fetch(<<"use_endpoint_privacy">>, 'true', Call),
    case UseEndpoint of
        'true' -> get_user_privacy_flags(Call, UserId);
        'false' ->
            CCVs = kapps_call:custom_channel_vars(Call),
            kz_privacy:flags(CCVs)
    end.

get_user_privacy_flags(_, 'undefined') -> [];
get_user_privacy_flags(Call, UserId) ->
    AccountDb = kapps_call:account_db(Call),
    UserDoc = load_user_doc(AccountDb, UserId),
    kz_privacy:flags(UserDoc).

route_call(Data, Call) ->
    AccountId = kapps_call:account_id(Call),
    %ToNumber = knm_converters:normalize(kapps_call:request_user(Call)),
    ToNumber = cf_util:normalize_capture_group(kapps_call:kvs_fetch('cf_capture_group', Call), AccountId),
    lager:info("attempting to route call to: ~s", [ToNumber]),
    UpdatedCall = kapps_call:set_request(list_to_binary([ToNumber, "@", kapps_call:request_realm(Call)]), Call),
    cf_exe:set_call(UpdatedCall),
    case maybe_route_user(ToNumber, AccountId) of
        'true' ->
            lager:debug("trying to route call to account user", []),
            AccountDb = kapps_call:account_db(Call),
            UserId = user_lookup(AccountDb, ToNumber),
            try_route_user(UserId, ToNumber, Data, UpdatedCall);
        'false' ->
            lager:debug("trying to route call offnet", []),
            try_route_offnet(UpdatedCall)
    end.

maybe_route_user(Number, AccountId) ->
    case knm_number:lookup_account(Number) of
        {'ok', AccountId, NumberProps} = _R ->
            ForceOffnet = knm_number_options:should_force_outbound(NumberProps),
            lager:debug("number <~s> belongs to this account (~s) - force offnet: ~p", [Number, AccountId, ForceOffnet]),
            ForceOffnet =:= 'false';
        _R ->
            lager:debug("number <~s> does not belong to this account (~s)" ,[Number, AccountId]),
            'false'
    end.

%% Route offnet
try_route_offnet(Call) ->
    AllowNoMatch = cf_route_req:allow_no_match(Call),
    lager:debug("offnet route to no_match allowed: ~p", [AllowNoMatch]),
    case AllowNoMatch of
        true -> cf_exe:continue(<<"offnet">>, Call);
        false -> cf_exe:continue(Call)
    end.

%% Route to user
try_route_user('undefined', ValidNumber, _, Call) ->
    lager:info("Rejecting call to ~s, number not assigned to user", [ValidNumber]),
    _ = kapps_call_command:response(404, "Not Found", Call),
    cf_exe:stop(Call);
try_route_user(UserId, ValidNumber, Data, Call) ->
    AccountDb = kapps_call:account_db(Call),
    UserDoc = load_user_doc(AccountDb, UserId),
    UserEnabled = kz_json:get_value(<<"enabled">>, UserDoc),
    Blacklist = kz_json:get_value(<<"blacklist">>, UserDoc),
    ValidName = formatNumberToName(ValidNumber),
    Props = props:filter_undefined([{<<"Callee-ID-Name">>, ValidName}
                                  ,{<<"Callee-ID-Number">>, ValidNumber}
                                  ,{<<"Callee-Owner-ID">>, UserId}
                                  ,{<<"Calling-Owner-ID">>, UserId}
                                 ]),
    Updates = [fun(C) -> kapps_call:set_callee_id_name(ValidName, C) end
              ,fun(C) -> kapps_call:set_callee_id_number(ValidNumber, C) end
              ,fun(C) -> kapps_call:set_custom_channel_vars(Props, C) end
              ],
    lager:info("validated callee id: \"~s\" <~s>", [ValidName, ValidNumber]),
    UpdatedCall = kapps_call:exec(Updates, Call),
    cf_exe:set_call(UpdatedCall),

    case maybe_block_call(UserEnabled, Blacklist, UpdatedCall) of
       'false' ->
           _ = add_missed_call_handler(Data, UpdatedCall),
           _ = store_last_caller_number(UserDoc, AccountDb, UpdatedCall),
           Endpoints = get_endpoints(UserId, Data, UpdatedCall),
           maybe_bridge_whitelisted(kz_json:set_values([{<<"user_id">>, UserId}], Data)
                       ,UpdatedCall
                       ,Endpoints
                       ,UserDoc
                       );
       {Code, Cause} -> block_call(Code, Cause, UpdatedCall)
     end.

block_call(Code, Cause, Call) ->
    lager:info("blocking call ~s ~s", [Code, Cause]),
    _ = kapps_call_command:response(Code, Cause, Call),
    cf_exe:stop(Call).

formatNumberToName(<<"+", Number/binary>>) -> Number;
formatNumberToName(Number) -> Number.

number_lookup(AccountDb, UserId, CandidateNumber) ->
    ViewOptions =  [{'key', [UserId, 'number']}],
    case kz_datamgr:get_results(AccountDb, <<"attributes/owned">>, ViewOptions) of
        {'ok', []} ->
            lager:debug("user does not have any allocated numbers", []),
            'undefined';
        {'ok', Matches} ->
            Numbers = [kz_json:get_ne_binary_value(<<"value">>, Match) || Match <- Matches],
            lager:debug("valid user external numbers ~p", [Numbers]),
            [FirstNumber | _] = Numbers,
            number_lookup_filter(Numbers, CandidateNumber, FirstNumber);
        _E -> 'undefined'
    end.

number_lookup_filter(_, 'undefined', FirstNumber) -> FirstNumber;
number_lookup_filter([], _, FirstNumber) -> FirstNumber;
number_lookup_filter([Number|_], Number, _) -> Number;
number_lookup_filter([_|Numbers], CandidateNumber, FirstNumber) -> number_lookup_filter(Numbers, CandidateNumber, FirstNumber).


maybe_block_call('false', _, _) -> {<<"410">>, <<"Gone">>};
maybe_block_call('true', Blacklist, Call) ->
    CCVs = kapps_call:custom_channel_vars(Call),
    case kz_privacy:is_anonymous(CCVs) of
        'true' -> should_block_anonymous(Blacklist);
        'false' -> is_blacklisted(Blacklist, get_caller_number(Call))
    end.

should_block_anonymous(Blacklist) ->
    case kz_json:is_true(<<"should_block_anonymous">>, Blacklist) of
        'false' -> 'false';
        'true' ->
            lager:info("anonymous call not allowed", []),
%            {<<"433">>, <<"Anonymity Disallowed">>}
            {<<"603">>, <<"Anonymity Disallowed">>}

    end.

is_blacklisted(Blacklist, Number) ->
    Numbers = kz_json:get_value(<<"numbers">>, Blacklist, []),
    lager:debug("checking user blacklist ~p for ~p", [Numbers, Number]),
    case lists:member(Number, Numbers) of
        'true'  ->
            lager:info("~s is blacklisted", [Number]),
            {<<"603">>, <<"Decline">>};
        'false' -> 'false'
   end.

 store_last_caller_number(UserDoc, AccountDb, Call) ->
    CCVs = kapps_call:custom_channel_vars(Call),
    FromNumber = case kz_privacy:is_anonymous(CCVs) of
                    'true' ->
                        AccountId = kz_util:format_account_id(AccountDb),
                        kz_privacy:anonymous_caller_id_name(AccountId);
                    'false' ->
                        get_caller_number(Call)
                 end,
    LastCallerJObj = kz_json:from_list([{<<"number">>, FromNumber}
                                       ,{<<"call_id">>, kapps_call:call_id(Call)}
                                       ,{<<"time">>, kz_time:now_s()}
                                      ]),
    Updated = kz_json:set_value([<<"last_caller">>], LastCallerJObj, UserDoc),
    %% interaction_time
    %% call_id
    case kz_datamgr:save_doc(AccountDb, Updated) of
        {'ok', _}=Ok ->
            lager:info("last caller set to ~s on document ~s", [FromNumber, kz_doc:id(UserDoc)]),
            Ok;
        {'error', 'conflict'} ->
            case kz_datamgr:open_doc(AccountDb, kz_doc:id(UserDoc)) of
                {'error', _}=E -> E;
                {'ok', NewJObj} -> store_last_caller_number(NewJObj, AccountDb, Call)
            end;
        {'error', _}=E -> E
    end.

user_lookup(AccountDb, Number) ->
    ViewOptions =  [{'key', [Number, 'user']}],
    case kz_datamgr:get_results(AccountDb, <<"attributes/number_lookup">>, ViewOptions) of
        {'ok', []} -> maybe_fetch_user_from_port(Number);
        {'ok', [Match|_]} ->
            OwnerId = kz_json:get_ne_binary_value(<<"value">>, Match),
            lager:debug("number ~s belongs to user ~s", [Number, OwnerId]),
            OwnerId;
        _E -> 'undefined'
    end.

maybe_fetch_user_from_port(Number) ->
    case knm_port_request:get(Number) of
        {'error', _E} -> 'undefined';
        {'ok', Port} ->
            OwnerId = kz_json:get_value(<<"owner_id">>, Port),
            PortState = kz_json:get_value(<<"pvt_port_state">>, Port),
            lager:debug("Port found for ~s with state ~s and owner ~s", [Number, PortState, OwnerId]),
            case PortState of
                <<"staged">> -> OwnerId;
                _ -> 'undefined'
            end
    end.

maybe_forward_to_vm(UserDoc, Data, Call) ->
    case user_vm_enabled(UserDoc) =:= true andalso user_vm_default_vbox(UserDoc) of
		false ->
		    lager:debug("continuing, VMbox not enabled for user ~s", [kz_doc:id(UserDoc)]),
            cf_exe:continue(Call);
        'undefined' ->
            lager:debug("continuing, VMbox not found for user ~s", [kz_doc:id(UserDoc)]),
            cf_exe:continue(Call);
        VmBoxId ->
            lager:debug("found voicemail box ~s for user ~s", [VmBoxId, kz_doc:id(UserDoc)]),
            Vals = [{<<"id">>, VmBoxId}
                   ,{<<"action">>, <<"compose">>}
                   ,{<<"callerid_match_login">>, true}
                   ,{<<"single_mailbox_login">>, true}
                   ,{<<"use_person_not_available">>, true}
                   ],
            VmData = kz_json:set_values(Vals, Data),
            cf_voicemail:handle(VmData, Call)
    end.

load_user_doc(_, 'undefined') -> [];
load_user_doc(AccountDb, UserId) ->
    case kz_datamgr:open_cache_doc(AccountDb, UserId) of
        {'ok', UserJObj} -> UserJObj;
        {'error', _} ->
            lager:debug("user no longer exists? ~s", [UserId]),
            []
    end.

user_vm_enabled(UserJObj) ->
    kz_json:is_true(<<"vm_enabled">>, UserJObj, false).

user_vm_default_vbox(UserJObj) ->
    kz_json:get_value(<<"vm_default_vbox">>, UserJObj, 'undefined').

ring_timeout(UserJObj, Default) ->
    case user_vm_enabled(UserJObj) of
        true -> kz_json:get_value(<<"vm_answer_timeout">>, UserJObj, ?DEFAULT_VM_ANSWER_TIMEOUT_S);
        false -> Default
    end.

maybe_bridge_whitelisted(Data, Call, Endpoints, UserDoc) ->
    Whitelist = kz_json:get_value(<<"whitelist">>, UserDoc),
    case whitelist_action(Whitelist, Call) of
        <<"reject">> -> maybe_forward_to_vm(UserDoc, Data, Call);
        <<"block">>  -> block_call(<<"603">>, <<"Decline">>, Call);
        <<"accept">> -> maybe_bridge(Data, Call, Endpoints, UserDoc);
        _            -> maybe_bridge(Data, Call, Endpoints, UserDoc)
    end.

whitelist_action('undefined', _) -> <<"accept">>;
whitelist_action(Whitelist, Call) ->
    Numbers = kz_json:get_value(<<"numbers">>, Whitelist, []),
    Action = kz_json:get_value(<<"action">>, Whitelist, <<"accept">>),
    Number = get_caller_number(Call),
    case is_whitelisted(Numbers, Number) of
        'true' -> <<"accpet">>;
        'false' -> Action
    end.

is_whitelisted([], _Number) -> <<"accept">>;
is_whitelisted(Numbers, Number) -> lists:member(Number, Numbers).

maybe_bridge(Data, Call, [], UserDoc) ->
    lager:notice("user ~s has no available endpoints"
                ,[kz_json:get_ne_binary_value(<<"user_id">>, Data)]
                ),
    maybe_forward_to_vm(UserDoc, Data, Call);

maybe_bridge(Data, Call, Endpoints, UserDoc) ->
    Whitelist = kz_json:get_value(<<"whitelist">>, UserDoc),
    case whitelist_action(Whitelist, Call) of
        <<"try_vm">> -> maybe_forward_to_vm(UserDoc, Data, Call);
        <<"reject">> -> block_call(<<"603">>, <<"Decline">>, Call);
        _ -> bridge(Data, Call, Endpoints, UserDoc)
    end.


bridge(Data, Call, Endpoints, UserDoc) ->
    FailOnSingleReject = kz_json:is_true(<<"fail_on_single_reject">>, Data, kapps_call:custom_channel_var(<<"Require-Fail-On-Single-Reject">>, Call)),
    Timeout = ring_timeout(UserDoc, kz_json:get_integer_value(<<"timeout">>, Data, ?DEFAULT_RING_TIMEOUT_S)),
    Strategy = kz_json:get_ne_binary_value(<<"strategy">>, Data, <<"simultaneous">>),
    IgnoreEarlyMedia = Strategy =:= <<"simultaneous">>
        orelse kz_endpoints:ignore_early_media(Endpoints),
    CustomSIPHeaders = kz_json:get_ne_json_value(<<"custom_sip_headers">>, Data),

    lager:info("attempting ~b user devices with strategy ~s", [length(Endpoints), Strategy]),

    case kapps_call_command:b_bridge(Endpoints
                                    ,Timeout
                                    ,Strategy
                                    ,IgnoreEarlyMedia
                                    ,'undefined' % Ringback
                                    ,CustomSIPHeaders
                                    ,<<"false">> % IgnoreForward
                                    ,FailOnSingleReject
                                    ,Call
                                    )
    of
        {'ok', _} ->
            lager:info("completed successful bridge to user"),
            cf_exe:stop(Call);
        {'fail', _}=Reason -> maybe_handle_bridge_failure(Reason, UserDoc, Data, Call);
        {'error', Error} ->
            Failure = kz_json:get_ne_binary_value(<<"Error-Message">>, Error),
            _ = maybe_send_offline_alert(Call, Failure),
            lager:info("error bridging to user: ~p", [Failure]),
            maybe_forward_to_vm(UserDoc, Data, Call)
    end.

maybe_handle_bridge_failure(Reason, UserDoc, Data, Call) ->
    case cf_util:handle_bridge_failure(Reason, Call) of
        'not_found' -> maybe_forward_to_vm(UserDoc, Data, Call);
        'ok' -> 'ok'
    end.

%%------------------------------------------------------------------------------
%% @doc Loop over the provided endpoints for the callflow and build the
%% json object used in the bridge API
%% @end
%%------------------------------------------------------------------------------
-spec get_endpoints(kz_term:api_binary(), kz_json:object(), kapps_call:call()) ->
          kz_json:objects().
get_endpoints('undefined', _, _) -> [];
get_endpoints(UserId, Data, Call) ->
    Params = kz_json:set_value(<<"source">>, kz_term:to_binary(?MODULE), Data),
    kz_endpoints:by_owner_id(UserId, Params, Call).

add_missed_call_handler(Data, Call) -> cf_exe:add_termination_handler(Call, {'cf_missed_call_alert', 'handle_termination', [Data]}).

maybe_send_offline_alert(Call, <<"registrar returned no endpoints">>) ->
    lager:debug("trying to publish offline_call_alert for call-id ~s", [kapps_call:call_id_direct(Call)]),
    Props = props:filter_undefined(
              [{<<"From-User">>, kapps_call:from_user(Call)}
              ,{<<"From-Realm">>, kapps_call:from_realm(Call)}
              ,{<<"To-User">>, kapps_call:to_user(Call)}
              ,{<<"To-Realm">>, kapps_call:to_realm(Call)}
              ,{<<"Account-ID">>, kapps_call:account_id(Call)}
              ,{<<"Owner-ID">>, kapps_call:custom_channel_var(<<"Callee-Owner-ID">>, Call)}
              ,{<<"Caller-ID-Number">>, kapps_call:caller_id_number(Call)}
              ,{<<"Caller-ID-Name">>, kapps_call:caller_id_name(Call)}
              ,{<<"Timestamp">>, kz_time:now_s()}
              ,{<<"Call-ID">>, kapps_call:call_id_direct(Call)}
              ,{<<"Call-Bridged">>, kapps_call:call_bridged(Call)}
               | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
              ]
             ),
    kapps_notify_publisher:cast(Props, fun kapi_notifications:publish_offline_call/1);
maybe_send_offline_alert(_Call, _Error) -> 'ok'.