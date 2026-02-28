%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2021, 2600Hz
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(webhooks_object).

-export([init/0
        ,bindings_and_responders/0
        ,account_bindings/1
        ,handle_event/2
        ]).

-include("webhooks.hrl").
-include_lib("kazoo_amqp/include/kapi_conf.hrl").
-include_lib("kazoo_documents/include/doc_types.hrl").

-define(ID, kz_term:to_binary(?MODULE)).
-define(HOOK_NAME, <<"object">>).
-define(NAME, <<"Object">>).
-define(DESC, <<"Receive notifications when objects (like JSON document objects) in Kazoo are changed">>).

-define(OBJECT_TYPES
       ,kapps_config:get(?APP_NAME, <<"object_types">>, ?DOC_TYPES)
       ).

-define(TYPE_MODIFIER
       ,kz_json:from_list(
          [{<<"type">>, <<"array">>}
          ,{<<"description">>, <<"A list of object types to handle">>}
          ,{<<"items">>, ?OBJECT_TYPES}
          ]
         )
       ).

-define(ACTIONS_MODIFIER
       ,kz_json:from_list(
          [{<<"type">>, <<"array">>}
          ,{<<"description">>, <<"A list of object actions to handle">>}
          ,{<<"items">>, ?DOC_ACTIONS ++ [<<"all">>]}
          ]
         )
       ).

-define(MODIFIERS
       ,kz_json:from_list(
          [{<<"type">>, ?TYPE_MODIFIER}
          ,{<<"action">>, ?ACTIONS_MODIFIER}
          ]
         )
       ).

-define(METADATA
       ,kz_json:from_list(
          [{<<"_id">>, ?ID}
          ,{<<"name">>, ?NAME}
          ,{<<"description">>, ?DESC}
          ,{<<"modifiers">>, ?MODIFIERS}
          ]
         )
       ).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    webhooks_util:init_metadata(?ID, ?METADATA).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec bindings_and_responders() -> {gen_listener:bindings(), gen_listener:responders()}.
bindings_and_responders() ->
    Bindings = bindings(),
    Responders = [{{?MODULE, 'handle_event'}, [{<<"configuration">>, <<"*">>}]}],
    {Bindings, Responders}.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec account_bindings(kz_term:ne_binary()) -> gen_listener:bindings().
account_bindings(_AccountId) -> [].

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), kz_term:proplist()) -> any().
handle_event(JObj, _Props) ->
    kz_util:put_callid(JObj),
    'true' = kapi_conf:doc_update_v(JObj),
    lager:debug("API: ~p", [JObj]),
    AccountId = find_account_id(JObj),
    case AccountId =/= 'undefined'
        andalso webhooks_util:find_webhooks(?HOOK_NAME, AccountId) of
        'false' -> 'ok';
        [] ->
            lager:debug("no hooks to handle ~s for ~s"
                       ,[kz_api:event_name(JObj), AccountId]
                       );
        Hooks ->
            Event = format_event(JObj, AccountId),
            Action = kz_api:event_name(JObj),
            Type = kapi_conf:get_type(JObj),
            lager:debug("Action: ~s Type: ~s Event: ~p Hooks: ~p", [Action, Type, Event, Hooks]),
            Filtered = [Hook || Hook <- Hooks, match_action_type(Hook, Action, Type)],
            webhooks_util:fire_hooks(Event, Filtered)
    end.

-spec match_action_type(webhook(), kz_term:api_binary(), kz_term:api_binary()) -> boolean().
match_action_type(#webhook{hook_event = ?HOOK_NAME
                          ,custom_data='undefined'
                          }, _Action, _Type) ->
    'true';
match_action_type(#webhook{hook_event = ?HOOK_NAME
                          ,custom_data=JObj
                          }, Action, Type) ->
    kz_json:get_value(<<"type">>, JObj) =:= Type
        andalso (kz_json:get_value(<<"action">>, JObj) =:= Action
                orelse kz_json:get_value(<<"action">>, JObj) =:= <<"all">>);
match_action_type(#webhook{}, _Action, _Type) ->
    'true'.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================


%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec bindings() -> gen_listener:bindings().
bindings() ->
    [{'conf', [{'restrict_to', ['doc_updates']}]}].

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec format_event(kz_json:object(), kz_term:ne_binary()) -> kz_json:object().
format_event(JObj, AccountId) ->
    %% normalise keys and include all the data for the event
    Event = kz_json:normalize(JObj),
    %% -BNP we actually want the event_name as type (object doc name)
    %% and add an event_action as event_name (edit/modify/created)
    %% rename the category as the hook (object)
    Updates = [{<<"account_id">>, AccountId}
              ,{<<"event_name">>, kapi_conf:get_type(JObj)}
              ,{<<"event_action">>, kz_api:event_name(JObj)}
              ,{<<"event_category">>, ?HOOK_NAME}
              ],
    kz_json:set_values(Updates, Event).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec find_account_id(kz_json:object()) -> kz_term:ne_binary().
find_account_id(JObj) ->
    DB = kapi_conf:get_database(JObj),
    find_account_id(kzs_util:db_classification(DB), DB, JObj).

-spec find_account_id(atom(), kz_term:ne_binary(), kz_term:ne_binary()) -> kz_term:ne_binary().
find_account_id(Classification, DB, _JObj)
  when Classification =:= 'account';
       Classification =:= 'modb' ->
    kz_util:format_account_id(DB, 'raw');
find_account_id('aggregate', <<"accounts">>, JObj) -> kapi_conf:get_id(JObj);
find_account_id('aggregate', <<"port_requests">>, JObj) -> kapi_conf:get_account_id(JObj);
find_account_id(_, _, _) -> 'undefined'.
