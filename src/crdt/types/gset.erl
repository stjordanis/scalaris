%  @copyright 2008-2018 Zuse Institute Berlin

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

%% @author Jan Skrzypczak <skrzypczak@zib.de>
%% @doc Implementation of a G-Set (Grow-only Set) state-based CRDT.
%% @end
%% @version $Id$

-module(gset).
-author('skrzypczak@zib.de').
-vsn('Id$').

-include("scalaris.hrl").

-export([update_add/2]).
-export([query_lookup/2]).


-behaviour(crdt_beh).

-opaque crdt() :: ordsets:ordset().

-include("crdt_beh.hrl").

-spec new() -> crdt().
new() -> [0 || _ <- ordsets:new()].

-spec merge(crdt(), crdt()) -> crdt().
merge(CRDT1, CRDT2) -> ordsets:union(CRDT1, CRDT2).

-spec eq(crdt(), crdt()) -> boolean().
eq(CRDT1, CRDT2) -> CRDT1 =:= CRDT2.

-spec lteq(crdt(), crdt()) -> boolean().
lteq(CRDT1, CRDT2) -> ordsets:is_subset(CRDT1, CRDT2).

%%%%%%%%%%%%%%% Available update and query functions

-spec update_add(non_neg_integer(), crdt()) -> crdt().
update_add(ToAdd, CRDT) -> ordsets:add_element(ToAdd, CRDT).

-spec query_lookup(any(), crdt()) -> boolean().
query_lookup(Element, CRDT) -> ordsets:is_element(Element, CRDT).


