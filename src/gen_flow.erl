%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(gen_flow).
-author('Christopher Meiklejohn <christopher.meiklejohn@gmail.com>').

%% API
-export([start_link/2,
         start_link/3,
         loop/3]).

%% System message callbacks
-export([system_continue/3,
         system_terminate/4,
         system_get_state/1,
         system_replace_state/2]).

%% Callbacks
-export([init/4]).

%% Ignore explicit termination warning.
-dialyzer([{nowarn_function, [system_terminate/4]}]).

%%%===================================================================
%%% Behaviour
%%%===================================================================

-type state() :: state().

-record(state, {pids :: [pid()],
                module :: atom(),
                module_state :: term(),
                cache :: orddict:orddict(),
                max_events :: non_neg_integer() | undefined}).

-callback init(list(term())) -> {ok, state()}.
-callback read(state()) -> {ok, [function()], state()}.
-callback process(list(term()), state()) -> {ok, {boolean(), state()}}.

%%%===================================================================
%%% API
%%%===================================================================

start_link(Module, Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Module, Args, undefined]).

start_link(Module, MaxEvents, Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Module, Args, MaxEvents]).

%%%===================================================================
%%% Callbacks
%%%===================================================================

%% @doc TODO
init(Parent, Module, Args, MaxEvents) ->
    %% Trap exits from children.
    process_flag(trap_exit, true),

    %% Initialize state.
    {ok, ModuleState} = case Module:init(Args) of
        {ok, InitState} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            {ok, InitState};
        {error, Reason} ->
            exit(Reason)
    end,

    %% Create debugging structure.
    Debug = sys:debug_options([]),

    %% Initialize state.
    State = #state{pids=[],
                   module=Module,
                   module_state=ModuleState,
                   cache=orddict:new(),
                   max_events=MaxEvents},

    loop(Parent, Debug, State).

% If we have reached the max number of events, stop the process
loop(_, _, #state{pids=Pids, max_events=0}) -> terminate(Pids), ok;

%% @doc TODO
loop(Parent, Debug, #state{pids=Pids0,
                           cache=Cache0,
                           module=Module,
                           max_events=MaxEvents,
                           module_state=ModuleState0}=State) ->

    %% Terminate pids that might still be running.
    terminate(Pids0),

    %% Clear EXIT messages from previous pids
    clear_exit_inbox(Parent),

    %% Get self.
    Self = self(),

    %% Gather the read functions.
    {ok, ReadFuns, ReadState} = Module:read(ModuleState0),

    %% Initialize bottom values in orddict.
    DefaultedCache = lists:foldl(fun(X, C) ->
                case orddict:find(X, C) of
                    error ->
                        orddict:store(X, undefined, C);
                    {ok, _} ->
                        C
                end
        end, Cache0, lists:seq(1, length(ReadFuns))),

    %% For each readfun, spawn a linked process to request values.
    Pids = lists:map(fun(X) ->
            ReadFun = lists:nth(X, ReadFuns),
            CachedValue = orddict:fetch(X, DefaultedCache),
            Pid = spawn_link(fun() ->
                                Value = ReadFun(CachedValue),
                                Self ! {ok, X, Value}
                        end),
            Pid
        end, lists:seq(1, length(ReadFuns))),

    %% Wait for responses.
    receive
        hibernate ->
            %% Terminate pids.
            terminate(Pids),
            %% Clear the inbox so we don't wake up immediately
            clear_inbox(),

            %% Hibernate
            proc_lib:hibernate(?MODULE,
                               loop,
                               [Parent,
                                Debug,
                                State#state{module_state=ModuleState0,
                                            cache=Cache0,
                                            pids=[]}]);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, State),
            loop(Parent, Debug, State#state{module_state=ModuleState0, cache=Cache0, pids=Pids});

        {ok, X, V} ->
            %% Log result.
            Debug1 = sys:handle_debug(Debug,
                                      fun write_debug/3,
                                      ?MODULE,
                                      {ok, X, V}),

            %% Update cache.
            Cache = orddict:store(X, V, DefaultedCache),

            %% Get current values from cache.
            RealizedCache = [Value || {_, Value} <- orddict:to_list(Cache)],

            %% Call process function.
            {ok, {Processed, ModuleState}} = Module:process(RealizedCache, ReadState),

            %% If a maximum number of events was given, update the count.
            case MaxEvents of
                undefined ->
                    loop(Parent, Debug1, State#state{pids=Pids,
                                                     cache=Cache,
                                                     module_state=ModuleState});
                _ ->
                    Events = case Processed of
                        true -> MaxEvents - 1;
                        _ -> MaxEvents
                    end,
                    loop(Parent, Debug1, State#state{pids=Pids,
                                                     cache=Cache,
                                                     max_events=Events,
                                                     module_state=ModuleState})
            end;

        {'EXIT', Parent, Reason} ->
            exit(Reason)

    after
        60000 ->
            %% If 60 seconds go by, relaunch.
            loop(Parent, Debug, State#state{module_state=ModuleState0, cache=Cache0, pids=Pids})
    end.

%% @private
write_debug(Dev, Event, Name) ->
    io:format(Dev, "~p event = ~p~n", [Name, Event]).

%% @private
system_continue(Parent, Debug, State) ->
    loop(Parent, Debug, State).

%% @private
system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

%% @private
system_get_state(State) ->
    {ok, State, State}.

%% @private
system_replace_state(StateFun, State) ->
    NewState = StateFun(State),
    {ok, NewState, NewState}.

%% @private
clear_inbox() ->
    receive
        _ -> clear_inbox()
    after
        0 -> ok
    end.

%% @private
clear_exit_inbox(Parent) ->
    receive
        {'EXIT', Parent, Reason} -> exit(Reason);
        {'EXIT', _, _} -> clear_exit_inbox(Parent)
    after
        0 -> ok
    end.

%% @private
terminate(Pids) ->
    %% Terminate pids that might still be running.
    TerminateFun = fun(Pid) ->
                           exit(Pid, kill)
                   end,
    _ = [TerminateFun(Pid) || Pid <- Pids],
    ok.
