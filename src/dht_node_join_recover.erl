% @copyright 2007-2014 Zuse Institute Berlin

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc Join ring on recover.
%% @version $Id$
-module(dht_node_join_recover).
-author('schuett@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").
-include("record_helpers.hrl").

-export([join/1]).

-spec join(Options::[tuple()]) -> dht_node_state:state().
join(Options) ->
    % 1. get old lease databases
    LeaseDBs = [get_db(Options, erlang:list_to_atom("lease_db-" ++ erlang:integer_to_list(I))) || I <- lists:seq(1, config:read(replication_factor))],
    % 2. find old leases
    LeaseList = lease_recover:recover(LeaseDBs),
    % 3. create state with old mnesias
    MyId = l_on_cseq:get_id(lease_list:get_active_lease(LeaseList)),
    Me = node:new(comm:this(), MyId, 0), 
    Neighbors = nodelist:new_neighborhood(Me), % needed for ?RT:empty_ext/1
    EmptyRT = ?RT:empty_ext(Neighbors), % only for rt_chord
    RMState = rm_loop:init(Me, Me, Me, null),
    PRBR_KV_DB = get_db(Options, prbr_kv_db),
    TXID_DBs = [get_db(Options, erlang:list_to_atom("tx_id-" ++ erlang:integer_to_list(I))) || I <- lists:seq(1, config:read(replication_factor))],
    State = dht_node_state:new_on_recover(EmptyRT, RMState,
                               PRBR_KV_DB, TXID_DBs, LeaseDBs, LeaseList),
    % 3. after the leases are known, we can start ring-maintenance and routing
    % 4. now we can try to refresh the local leases
    msg_delay:send_trigger(1, {l_on_cseq, renew_leases}),

    % copied from dht_node_join
    rt_loop:activate(Neighbors),
    dc_clustering:activate(),
    gossip:activate(Neighbors),
    dht_node_reregister:activate(),
    service_per_vm:register_dht_node(node:pidX(Me)),
    State.

get_db(Options, DBName) ->
    case lists:keyfind(DBName, 1, Options) of
        false ->
            log:log("error: Options:~p ~nDBName:~w", [Options, DBName]),
            log:log("error in dht_node_join_recover:get_db/2. The mnesia database ~w was not found in the dht_node options (~w)", [DBName, Options]),
            ok; % will fail in tab2list
        {DBName, DB} ->
            db_prbr:open(DB)
    end.
