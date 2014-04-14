%  @copyright 2014 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Maximilian Michels <michels@zib.de>
%% @doc Implementation of a modified version of the paper below. This implementation 
%%      doesn't use virtual servers but can still benefit from the load balancing
%%      algorithm's attributes, respectively the load directories and the emergency
%%      transfer of load. In addition, gossipping information has been added to improve
%%      the balancing process.
%%
%%      Many-to-Many scheme
%%
%% @reference B. Godfrey, S. Surana, K. Lakshminarayanan, R. Karp, and I. Stoica
%%            "Load balancing in dynamic structured peer-to-peer systems"
%%            Performance Evaluation, vol. 63, no. 3, pp. 217-240, 2006.
%%
%% @version $Id$
-module(lb_active_directories).
-author('michels@zib.de').
-vsn('$Id$').

-behavior(lb_active_beh).
%% implements
-export([init/0, check_config/0]).
-export([handle_msg/2, handle_dht_msg/2]).
-export([get_web_debug_key_value/1]).

-include("scalaris.hrl").
-include("record_helpers.hrl").

%% Defines the number of directories
%% e.g. 1 implies a central directory
-define(NUM_DIRECTORIES, 5).

-define(TRACE(X,Y), ok).
%-define(TRACE(X,Y), io:format(X,Y)).

-type utilization() :: float().

-record(node, {utilization = ?required(node, utilization)    :: utilization(), %% erlang sorts by first element in record/tuple
               pid      = ?required(node, pid)               :: comm:mypid(),
               capacity = 1                                  :: number(),
               load     = ?required(node, load)              :: number()
               }).

-type directory_name() :: string().

-record(directory, {name         = ?required(directory, name) :: directory_name(), 
                    last_balance = nil                        :: nil | os:timestamp(),
                    pool         = gb_sets:new()              :: gb_set(),
                    schedule     = []                         :: [reassign()]
                    }).

-record(reassign, {from = ?required(reassign, from) :: node:node_type(),
                   to   = ?required(reassign, to)   :: node:node_type()
                   }).

-type reassign() :: #reassign{}.

-record(state, {capacity = 1500, %% free cpu usage, free memory, bandwith...
                my_dirs = [],
                threshold_periodic  = 0.5, %% k_p = (1 + average directory utilization) / 2
                threshold_emergency = 1.0  %% k_e
                }).

-type directory() :: #directory{}.
-type node() :: #node{}.

-type state() :: #state{}.

-type trigger() :: publish_trigger | directory_trigger.

-type dht_message() :: none.

-spec init() -> state().
init() ->
    create_directories(?NUM_DIRECTORIES),
    %% post load to random directory
    %% post_load(rand_directory),
    trigger(publish_trigger),
    trigger(directory_trigger),
    request_dht_range(),
    This = comm:this(),
    rm_loop:subscribe(
       self(), ?MODULE, fun rm_loop:subscribe_dneighbor_change_slide_filter/3,
       fun(_,_,_,_) -> comm:send_local(self(), {get_state, This, my_range}) end, inf),
    #state{}.

handle_msg({publish_trigger}, State) ->
    trigger(publish_trigger),
    case emergency of %% emergency when load(node) > k_e
      true ->
         %post_load(),
         %get && perform_transfer()
         ok;
      _ ->
         %get && perform transfer() without overloading
         %post_load()
         ok
    end,
    State;

%% In case of an emergency, we check immediately
handle_msg({emergency, LoadInfo, DirKey}, State) ->
    %% TODO just write directly to db instead
    post_load_to_directory(LoadInfo, DirKey),
    %% TODO Emergency Threshold has been already check at the node overloaded...
    EmergencyThreshold = State#state.threshold_emergency,
    case LoadInfo#node.utilization > EmergencyThreshold of
        true  ->
            MyDirKeys = State#state.my_dirs,
            directory_routine(DirKey, emergency);
        false -> State
    end;

handle_msg({directory_trigger}, State) ->
    trigger(directory_trigger),
    ?TRACE("~p My Directories: ~p~n", [self(), State#state.my_dirs]),
    %% Threshold k_p = Average laod in directory
    %% Threshold k_e = 1 meaning full capacity
    %% Upon receipt of load information:
    %%      add_to_directory(load_information),
    %%      case node_overloaded of
    %%          true -> compute_reassign(directory_load, node, k_e);
    %%          _    -> compute_reassign(directory_load, node, k_p),
    %%                  clear_directory()
    %%      end
    %% compute_reassign:
    %%  for every node from heavist to lightest in directory 
    %%    if l_n / c_n > k 
    %%       balance such that (l_n + l_x) / c_n gets minimized
    %%  return assignment
    MyDirKeys = State#state.my_dirs,
    manage_directories(MyDirKeys),
    State;

handle_msg({get_state_response, MyRange}, State) ->
    Directories = get_all_directory_keys(),
    MyDirectories = [Dir || Dir <- Directories, intervals:in(Dir, MyRange)],
    ?TRACE("~p: I am responsible for ~p~n", [self(), MyDirectories]),
    State#state{my_dirs = MyDirectories};

handle_msg(Msg, State) ->
    ?TRACE("Unknown message: ~p~n", [Msg]),
    State.

%% @doc Load balancing messages received by the dht node.
-spec handle_dht_msg(dht_message(), dht_node_state:state()) -> dht_node_state:state().
handle_dht_msg({lb_active, Msg}, DhtState) ->
    DhtState.

manage_directories([]) ->
    ok;
manage_directories([DirKey | Rest]) ->
    directory_routine(DirKey, periodic),
    manage_directories(Rest).

directory_routine(DirKey, Type) ->
    %% Because of the lack of virtual servers/nodes, the load
    %% balancing is differs from the paper here. We try to
    %% balance the most loaded node with the least loaded
    %% node.
    %% TODO Some preference should be given to neighboring
    %%      nodes to avoid too many jumps.
    {TLog, Directory} = get_directory(DirKey),
    Pool = Directory#directory.pool,
    K = case Type of
            periodic ->
                AvgUtil = lists:foldl(fun(El, Acc) -> Acc + El#node.utilization end, 0, Pool) / length(Pool),
                (1 + AvgUtil) / 2;
            emergency ->
                1.0
        end,
    LightNodes = gb_sets:filter(fun(El) -> El#node.utilization =< K end, Pool),
    HeavyNodes = gb_sets:filter(fun(El) -> El#node.utilization >  K end, Pool),
    Schedule = find_matches(LightNodes, HeavyNodes, []),
    NewDirectory = dir_set_schedule(Schedule, dir_clear_load(Directory)),
    %% TODO Should this be inside a transcaction? We may not want atomic attributes here
    set_directory(TLog, NewDirectory),
    ok.

find_matches(LightNodes, HeavyNodes, Result) ->
    case gb_sets:size(LightNodes) > 0 andalso gb_sets:size(HeavyNodes) > 0 of
        true ->
            {LightNode, LightNodes2} = gb_sets:take_smallest(LightNodes),
            {HeavyNode, HeavyNodes2} = gb_sets:take_largest(HeavyNodes),
            find_matches(LightNodes2, HeavyNodes2, [{LightNode, HeavyNode} | Result]);
        false ->
            %% TODO we want to have the heaviest load first, this could be more efficient...
            lists:reverse(Result)
    end.

-spec request_dht_range() -> ok.
request_dht_range() ->
    MyDHT = pid_groups:get_my(dht_node),
    comm:send_local(MyDHT, {get_state, comm:this(), my_range}).

%% @doc Check if directories exist, if not create them.
-spec create_directories(non_neg_integer()) -> ok.
create_directories(0) ->
    ok;
create_directories(N) when N > 0 ->
    Key = int_to_str(get_directory_key_by_number(N)),
    TLog = api_tx:new_tlog(),

    case api_tx:read(TLog, Key) of
        {_TLog2, {ok, _Value}} ->
            create_directories(N-1);
        {TLog2, {fail, not_found}} ->
            {TLog3, _Result} = api_tx:write(TLog2, Key, #directory{name = Key}),
            case api_tx:commit(TLog3) of
                {ok} ->
                    create_directories(N-1);
                {fail, abort, [Key]} ->
                    create_directories(N)
            end
    end.

-spec get_all_directory_keys() ->  ?RT:key().
get_all_directory_keys() ->
    [get_directory_key_by_number(N) || N <- lists:seq(1, ?NUM_DIRECTORIES)].

-spec get_random_directory_key() ->  ?RT:key().
get_random_directory_key() ->
    Rand = randoms:rand_uniform(1, ?NUM_DIRECTORIES+1),
    get_directory_key_by_number(Rand).

-spec get_directory_key_by_number(pos_integer()) -> ?RT:key().
get_directory_key_by_number(N) when N > 0 ->
    ?RT:hash_key("lb_active_dir" ++ int_to_str(N)).

-spec post_load_to_directory(node(), directory_name()) -> ok.
post_load_to_directory(Load, DirKey) ->
    TLog = api_tx:new_tlog(),
    case api_tx:read(TLog, DirKey) of
        {TLog2, {ok, Content}} ->
            ContentNew = dir_add_load(Load, Content),
            {TLog3, _Result} = api_tx:write(TLog2, DirKey, ContentNew),
            case api_tx:commit(TLog3) of
                {ok} ->
                    ok;
                {fail, abort, [DirKey]} ->
                    log:log(warn, "~p: Failed to write to directory, retrying...", [?MODULE]),
                    post_load_to_directory(Load, DirKey)
            end;
        {_TLog2, {fail, not_found}} ->
            log:log(warn, "~p: Directory not found while posting load. This should never happen...", [?MODULE]),
            ok
    end.

-spec dir_add_load(node(), directory()) -> directory().
dir_add_load(Load, Directory) ->
    Pool = Directory#directory.pool,
    PoolNew = gb_sets:add(Load, Pool),
    Directory#directory{pool = PoolNew}.

-spec pop_load_in_directory(directory_name()) -> directory().
pop_load_in_directory(DirKey) ->
    TLog = api_tx:new_tlog(),
    case api_tx:read(TLog, DirKey) of
        {TLog2, {ok, Directory}} ->
            case api_tx:req_list(TLog2, [{write, DirKey, dir_clear_load(Directory)}, {commit}]) of
                {[], ok, ok} -> Directory;
                _ -> pop_load_in_directory(DirKey)
            end;
        {_TLog2, {fail, not_found}} ->
            log:log(warn, "~p: Directory not found while posting load. This should never happen...", [?MODULE])
    end.

-spec dir_clear_load(directory()) -> directory().
dir_clear_load(Directory) ->
    Directory#directory{pool = gb_sets:new()}.

dir_set_schedule(Schedule, Directory) ->
    Directory#directory{schedule = Schedule}.

get_directory(DirKey) ->
    TLog = api_tx:new_tlog(),
    case api_tx:read(TLog, DirKey) of
        {TLog2, {ok, Directory}} -> 
            {TLog2, Directory};
        _ -> 
            log:log(warn, "~p: Directory not found while posting load. This should never happen...", [?MODULE]),
            get_directory(DirKey)
    end.

-spec set_directory(api_tx:tlog(), directory()) -> ok | failed.
set_directory(TLog, Directory) ->
    DirKey = Directory#directory.name,
    case api_tx:req_list(TLog, [{write, DirKey, Directory}, {commit}]) of
        {[], ok, ok} -> 
            ok;
        _  ->
            log:log(warn, "~p: Failed to save directory ~p because of failed transaction.", [?MODULE, DirKey]),
            failed
    end.

%%%%%%%%%%%%
%% State
%%
-spec state_get(capacity, state()) -> number();
               (my_dirs,  state()) -> [directory_name()].
state_get(Key, #state{capacity = Capacity, 
                      my_dirs = Dirs}) ->
    case Key of
        capacity -> Capacity;
        my_dirs  -> Dirs
    end.

%%%%%%%%%%%%
%% Helpers
%%

-spec int_to_str(integer()) -> string().
int_to_str(N) ->
    erlang:integer_to_list(N).

-spec trigger(trigger()) -> ok.
trigger(Trigger) ->
    Interval = config:read(lb_active_interval),
    msg_delay:send_trigger(Interval div 1000, {Trigger}).

-spec get_web_debug_key_value(state()) -> [{string(), string()}].
get_web_debug_key_value(State) ->
    [{"state", webhelpers:html_pre(State)}].

-spec check_config() -> boolean().
check_config() ->
    % lb_active_interval => publish_interval
    % lb_active_intervak => balance_interval
    % emergency treshold
    true.