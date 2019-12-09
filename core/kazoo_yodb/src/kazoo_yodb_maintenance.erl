%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2019, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_yodb_maintenance).

-export([delete_yodbs/1
        ,delete_yodbs/2
        ]).
-export([archive_yodbs/0
        ,archive_yodbs/1
        ]).
-export([register_views/0]).

-include("kazoo_yodb.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec delete_yodbs(kz_term:ne_binary()) -> 'ok' | 'no_return'.
delete_yodbs(Period) ->
    delete_yodbs(Period, 'true').

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec delete_yodbs(kz_term:ne_binary(), boolean() | kz_term:ne_binary()) -> 'ok' | 'no_return'.
delete_yodbs(Period, ShouldArchive) ->
    Regex = <<"(2[0-9]{3})(0[1-9]|1[0-2])">>,
    case re:run(Period, Regex, [{'capture', 'all', 'binary'}]) of
        {'match', [_Full, Year, Month]} ->
            delete_yodbs(Year, Month, kz_term:is_true(ShouldArchive));
        'nomatch' ->
            io:format("period '~s' does not match YYYYMM format~n", [Period])
    end.

-spec delete_yodbs(kz_term:ne_binary() | kz_time:year(), kz_term:ne_binary() | kz_time:month(), boolean()) -> 'ok' | 'no_return'.
delete_yodbs(<<_/binary>> = Year, Month, ShouldArchive) ->
    delete_yodbs(kz_term:to_integer(Year), Month, ShouldArchive);
delete_yodbs(Year, <<_/binary>> = Month, ShouldArchive) ->
    delete_yodbs(Year, kz_term:to_integer(Month), ShouldArchive);
delete_yodbs(Year, Month, ShouldArchive) when is_integer(Year),
                                              is_integer(Month),
                                              Year > 2000,
                                              Year < 2999,
                                              Month > 0,
                                              Month < 13 ->
    case erlang:date() of
        {Year, Month, _} ->
            io:format("request to delete the current YODB (~p~p) denied~n", [Year, Month]);
        {CurrYear, CurrMonth, _} when (CurrYear * 12 + CurrMonth) > (Year * 12 + Month) ->
            io:format("deleting all YODBs equal to or older than ~p/~p~n", [Year, Month]),
            delete_older_yodbs(Year, Month, kapps_util:get_all_account_mods(), ShouldArchive);
        {_CurrYear, _CurrMonth, _} ->
            io:format("request to delete future YODBs (~p~p) denied~n", [Year, Month])
    end.

-spec delete_older_yodbs(kz_time:year(), kz_time:month(), kz_term:ne_binaries(), boolean()) -> 'no_return'.
delete_older_yodbs(Year, Month, AccountYodbs, ShouldArchive) ->
    Months = (Year * 12) + Month,
    _ = [delete_yodb(AccountYodb, ShouldArchive) || AccountYodb <- AccountYodbs, should_delete(AccountYodb, Months)],
    'no_return'.

-spec should_delete(kz_term:ne_binary(), pos_integer()) -> boolean().
should_delete(AccountYodb, Months) ->
    {_AccountId, ModYear, ModMonth} = kazoo_yodb_util:split_account_mod(AccountYodb),
    ((ModYear * 12) + ModMonth) =< Months.

-spec delete_yodb(kz_term:ne_binary(), boolean()) -> 'ok'.
delete_yodb(?MATCH_YODB_SUFFIX_UNENCODED(_,_) = AccountYodb, ShouldArchive) ->
    delete_yodb(kz_util:format_account_db(AccountYodb), ShouldArchive);
delete_yodb(?MATCH_YODB_SUFFIX_ENCODED(_,_) = AccountYodb, ShouldArchive) ->
    'ok' = case ShouldArchive of
               'true' -> kz_datamgr:db_archive(AccountYodb);
               'false' -> io:format("deleting database ~s~n", [AccountYodb])
           end,
    _Deleted = kz_datamgr:db_delete(AccountYodb),
    io:format("    deleted: ~p~n", [_Deleted]),
    timer:sleep(5 * ?MILLISECONDS_IN_SECOND).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec archive_yodbs() -> 'no_return'.
archive_yodbs() ->
    do_archive_yodbs(kapps_util:get_all_account_yods(), 'undefined').

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec archive_yodbs(kz_term:text()) -> 'no_return'.
archive_yodbs(AccountId) ->
    do_archive_yodbs(kapps_util:get_account_yods(AccountId), kz_term:to_binary(AccountId)).

-spec do_archive_yodbs(kz_term:ne_binaries(), kz_term:api_binary()) -> 'no_return'.
do_archive_yodbs(YODbs, AccountId) ->
    kz_log:put_callid(?MODULE),
    lists:foreach(fun kazoo_yodb:maybe_archive_yodb/1, YODbs),
    Keep = kapps_config:get_integer(?CONFIG_CAT, <<"active_yodbs">>, 6),
    From = case AccountId =:= 'undefined' of 'true' -> <<"all">>; 'false' -> AccountId end,
    io:format("archived ~s YODbs more than ~b months old~n", [From, Keep]),
    'no_return'.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec register_views() -> 'ok'.
register_views() ->
    kz_datamgr:register_views_from_folder('kazoo_yodb').
