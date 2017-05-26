% @copyright 2017 Zuse Institute Berlin

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
%% @doc SSL Acceptor.
%%
%%      This module accepts new ssl connections and starts corresponding
%%      comm_connection processes.
%% @version $Id$
-module(comm_ssl_acceptor).
-author('schuett@zib.de').
-vsn('$Id$').

-export([start_link/1, init/2, check_config/0]).

-include("gen_component.hrl").

-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(GroupName) ->
    Pid = spawn_link(?MODULE, init, [self(), GroupName]),
    receive
        {started, Pid} -> {ok, Pid}
    end.

-spec init(pid(), pid_groups:groupname()) -> any().
init(Supervisor, GroupName) ->
    Socket =
        try
            erlang:register(comm_layer_acceptor, self()),
            pid_groups:join_as(GroupName, comm_acceptor),

            IP = case config:read(listen_ip) of
                     undefined -> abort;
                     X         -> X
                 end,
            Port = config:read(port),

            log:log(info,"[ CC ] listening on ~p:~p", [IP, Port]),
            io:format("[ CC ] listening on ~p:~p~n", [IP, Port]),
            util:if_verbose("Listening on ~p:~p.~n", [IP, Port]),

            LS = open_listen_port(Port, IP),
            comm_server:set_local_address(IP, Port),
            io:format("this() == ~w~n", [{IP, Port}]), %
            LS
        catch
            % If init throws up, send 'started' to the supervisor but exit.
            % The supervisor will try to restart the process as it is watching
            % this PID.
            Level:Reason ->
                log:log(error,"Error: exception ~p:~p in ~p:init/2:  ~.0p",
                        [Level, Reason, ?MODULE, erlang:get_stacktrace()]),
                erlang:Level(Reason)
        after
            Supervisor ! {started, self()}
        end,
    server(Socket).

server(LS) ->
    io:format("server(LS)~n", []),
    case ssl:transport_accept(LS) of
        {ok, S} ->
            io:format("ssl:transport_accept(LS)~n", []),
            case ssl:ssl_accept(S) of
                {error, Reason} ->
                    io:format("ssl:ssl_accept(S): ~p~n", [Reason]),
                    foo;
                ok ->
                    io:format("ssl:ssl_accept(S)~n", []),
                    %% receive first message on the channel (generated by
                    %% comm_connection to get the listen port of the other side in order
                    %% to use the same connection for sending messages)
                    receive
                        {ssl, S, Msg} ->
                            {endpoint, Address, Port, Channel} = binary_to_term(Msg),
                            io:format("~p~n", [{endpoint, Address, Port, Channel}]),
                            %% auto determine remote address, if not sent correctly
                            NewAddress =
                                if Address =:= {0,0,0,0}
                                   orelse Address =:= {127,0,0,1} ->
                                        case ssl:peername(S) of
                                            {ok, {PeerAddress, _Port}} -> PeerAddress;
                                            {error, _Why} -> Address
                                        end;
                                   true -> Address
                                end,
                            ConnPid =
                                comm_server:create_connection(NewAddress, Port, S, Channel),
                            %% note: need to set controlling process from here as we created the socket
                            _ = ssl:controlling_process(S, ConnPid),
                            _ = ssl:setopts(S, comm_server:tcp_options(Channel)),
                            ok;
                        X ->
                            io:format("ssl:ssl_accept(S)~p~n", [X])
                    end
            end;
        Other ->
            log:log(warn,"[ CC ] unknown message ~p", [Other])
    end,
    server(LS).

-spec open_listen_port(comm_server:tcp_port(), IP::inet:ip_address()) -> inet:socket() | abort.
open_listen_port(Port, IP) ->
    case ssl:listen(Port, [
                           {certfile, config:read(certfile)},
                           {keyfile, config:read(keyfile)},
                           {secure_renegotiate, true},
                           binary,
                           {packet, 4},
                           {ip, IP},
                           {backlog, 128}
                          ]
                    ++ comm_server:tcp_options(main)) of
        {ok, ListenSocket} ->
            log:log(info,"[ CC ] listening on ~p:~p", [IP, Port]),
            ListenSocket;
        {error, Reason} ->
            log:log(error,"[ CC ] can't listen on ~p: ~p", [Port, Reason]),
            abort
    end.

%% @doc Checks whether config parameters exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_in(comm_backend, [ssl, gen_tcp]) and
    config:cfg_exists(certfile) and
    config:cfg_exists(keyfile) and
    config:cfg_is_port(port) and
    config:cfg_is_ip(listen_ip, true).
