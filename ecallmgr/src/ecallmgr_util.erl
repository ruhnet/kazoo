%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% Various utilities specific to ecallmgr. More general utilities go
%%% in whistle_util.erl
%%% @end
%%% Created : 15 Nov 2010 by James Aimonetti <james@2600hz.org>

-module(ecallmgr_util).

-export([get_sip_to/1, get_sip_from/1, get_orig_ip/1, custom_channel_vars/1]).
-export([to_hex/1, route_to_dialstring/2, route_to_dialstring/3, to_list/1, to_binary/1]).
-export([eventstr_to_proplist/1]).

-import(proplists, [get_value/2, get_value/3]).

-include("whistle_api.hrl").

%% retrieves the sip address for the 'to' field
-spec(get_sip_to/1 :: (Prop :: proplist()) -> binary()).
get_sip_to(Prop) ->
    list_to_binary([get_value(<<"sip_to_user">>, Prop, get_value(<<"variable_sip_to_user">>, Prop, ""))
		    , "@"
		    , get_value(<<"sip_to_host">>, Prop, get_value(<<"variable_sip_to_host">>, Prop, ""))
		   ]).

%% retrieves the sip address for the 'from' field
-spec(get_sip_from/1 :: (Prop :: proplist()) -> binary()).
get_sip_from(Prop) ->
    list_to_binary([
		    get_value(<<"sip_from_user">>, Prop, get_value(<<"variable_sip_from_user">>, Prop, ""))
		    ,"@"
		    , get_value(<<"sip_from_host">>, Prop, get_value(<<"variable_sip_from_host">>, Prop, ""))
		   ]).

-spec(get_orig_ip/1 :: (Prop :: proplist()) -> binary()).
get_orig_ip(Prop) ->
    get_value(<<"ip">>, Prop).

%% Extract custom channel variables to include in the event
-spec(custom_channel_vars/1 :: (Prop :: proplist()) -> proplist()).
custom_channel_vars(Prop) ->
    Custom = lists:filter(fun({<<"variable_", ?CHANNEL_VAR_PREFIX, _Key/binary>>, _V}) -> true;
			     (_) -> false
			  end, Prop),
    lists:map(fun({<<"variable_", ?CHANNEL_VAR_PREFIX, Key/binary>>, V}) -> {Key, V} end, Custom).

-spec(to_hex/1 :: (S :: term()) -> string()).
to_hex(S) ->
    string:to_lower(lists:flatten([io_lib:format("~2.16.0B", [H]) || H <- whistle_util:to_list(S)])).

-spec(route_to_dialstring/2 :: (Route :: binary() | list(binary()), Domain :: binary() | string()) -> binary()).
route_to_dialstring(<<"sip:", _Rest/binary>>=DS, _D) -> DS;
route_to_dialstring([<<"user:", User/binary>>, DID], Domain) ->
    list_to_binary([DID, "${regex(${sofia_contact(sipinterface_1/",User, "@", Domain, ")}|^[^\@]+(.*)|%1)}"]);
route_to_dialstring(DS, _D) -> DS.

%% for some commands, like originate, macros are not run; need to progressively build the dialstring
-spec(route_to_dialstring/3 :: (Route :: list(binary()), Domain :: string() | binary(), FSNode :: atom()) -> binary()).
route_to_dialstring([<<"user:", User/binary>>, DID], Domain, FSNode) ->
    {ok, SC} = freeswitch:api(FSNode, sofia_contact, binary_to_list(list_to_binary(["sipinterface_1/",User, "@", Domain]))),
    {ok, Regex} = re:compile("^[^\@]+"),
    re:replace(SC, Regex, DID, [{return, binary}]);
route_to_dialstring(X, _, _) -> X.

-spec(to_list/1 :: (X :: atom() | list() | binary() | integer() | float()) -> list()).
to_list(X) when is_float(X) ->
    mochinum:digits(X);
to_list(X) when is_integer(X) ->
    integer_to_list(X);
to_list(X) when is_binary(X) ->
    binary_to_list(X);
to_list(X) when is_atom(X) ->
    atom_to_list(X);
to_list(X) when is_list(X) ->
    X.

-spec(to_binary/1 :: (X :: atom() | list() | binary() | integer() | float()) -> binary()).
to_binary(X) when is_float(X) ->
    to_binary(mochinum:digits(X));
to_binary(X) when is_integer(X) ->
    to_binary(integer_to_list(X));
to_binary(X) when is_atom(X) ->
    list_to_binary(atom_to_list(X));
to_binary(X) when is_list(X) ->
    list_to_binary(X);
to_binary(X) when is_binary(X) ->
    X.

%% convert a raw FS string of headers to a proplist
%% "Event-Name: NAME\nEvent-Timestamp: 1234\n" -> [{<<"Event-Name">>, <<"NAME">>}, {<<"Event-Timestamp">>, <<"1234">>}]
-spec(eventstr_to_proplist/1 :: (EvtStr :: string()) -> proplist()).
eventstr_to_proplist(EvtStr) when is_list(EvtStr) ->
    lists:map(fun(X) ->
		      [K, V] = string:tokens(X, ": "),
		      [{V1,[]}] = mochiweb_util:parse_qs(V),
		      {whistle_util:to_binary(K), whistle_util:to_binary(V1)}
	      end, string:tokens(whistle_util:to_list(EvtStr), "\n")).
