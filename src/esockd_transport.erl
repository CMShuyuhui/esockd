%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% eSockd TCP/SSL or Proxy Transport
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_transport).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([type/1]).

-export([listen/2, send/2, async_send/2, recv/2, recv/3, async_recv/2, async_recv/3,
         controlling_process/2, close/1, fast_close/1]).

-export([getopts/2, setopts/2, getstat/2]).

-export([sockname/1, peername/1, shutdown/2]).

%% Peercert
-export([peercert/1, peer_cert_subject/1, peer_cert_common_name/1]).

-export([gc/1]).

%% tcp -> sslsocket
-export([ssl_upgrade_fun/1]).

-type(sock() :: inet:socket() | esockd:ssl_socket() | esockd:proxy_socket()).

-define(SSL_CLOSE_TIMEOUT, 5000).

-define(SSL_HANDSHAKE_TIMEOUT, 15000).

%%-compile({no_auto_import,[port_command/2]}).

%% @doc socket type: tcp | ssl | proxy
-spec(type(sock()) -> tcp | ssl | proxy).
type(Sock) when is_port(Sock) ->
    tcp;
type(#ssl_socket{ssl = _SslSock})  ->
    ssl;
type(#proxy_socket{}) ->
    proxy.

%% @doc Listen
-spec(listen(Port, SockOpts) -> {ok, Sock} | {error, Reason} when
    Port     :: inet:port_number(),
    SockOpts :: [gen_tcp:listen_option()],
    Sock     :: inet:socket(),
    Reason   :: system_limit | inet:posix()).
listen(Port, SockOpts) ->
    gen_tcp:listen(Port, SockOpts).

%% @doc Set Controlling Process of Socket
-spec(controlling_process(Sock, NewOwener) -> ok | {error, Reason} when
    Sock      :: sock(),
    NewOwener :: pid(),
    Reason    :: closed | not_owner | badarg | inet:posix()).
controlling_process(Sock, NewOwner) when is_port(Sock) ->
    gen_tcp:controlling_process(Sock, NewOwner);
controlling_process(#ssl_socket{ssl = SslSock}, NewOwner) ->
    ssl:controlling_process(SslSock, NewOwner).

%% @doc Close Sock
-spec(close(Sock :: sock()) -> ok).
close(Sock) when is_port(Sock) ->
    gen_tcp:close(Sock);
close(#ssl_socket{ssl = SslSock}) ->
    ssl:close(SslSock);
close(#proxy_socket{socket = Sock}) ->
    close(Sock).

-spec(fast_close(sock()) -> ok).
fast_close(Sock) when is_port(Sock) ->
    catch port_close(Sock), ok;
%% From rabbit_net.erl
fast_close(#ssl_socket{tcp = Sock, ssl = SslSock}) ->
    %% We cannot simply port_close the underlying tcp socket since the
    %% TLS protocol is quite insistent that a proper closing handshake
    %% should take place (see RFC 5245 s7.2.1). So we call ssl:close
    %% instead, but that can block for a very long time, e.g. when
    %% there is lots of pending output and there is tcp backpressure,
    %% or the ssl_connection process has entered the the
    %% workaround_transport_delivery_problems function during
    %% termination, which, inexplicably, does a gen_tcp:recv(Socket,
    %% 0), which may never return if the client doesn't send a FIN or
    %% that gets swallowed by the network. Since there is no timeout
    %% variant of ssl:close, we construct our own.
    {Pid, MRef} = spawn_monitor(fun() -> ssl:close(SslSock) end),
    erlang:send_after(?SSL_CLOSE_TIMEOUT, self(), {Pid, ssl_close_timeout}),
    receive
        {Pid, ssl_close_timeout} ->
            erlang:demonitor(MRef, [flush]),
            exit(Pid, kill);
        {'DOWN', MRef, process, Pid, _Reason} ->
            ok
    end,
    catch port_close(Sock), ok;
fast_close(#proxy_socket{socket = Sock}) ->
    fast_close(Sock).

%% @doc Send data.
-spec(send(Sock :: sock(), Data :: iodata()) -> ok | {error, Reason} when
    Reason :: closed | timeout | inet:posix()).
send(Sock, Data) when is_port(Sock) ->
    gen_tcp:send(Sock, Data);
send(#ssl_socket{ssl = SslSock}, Data) ->
    ssl:send(SslSock, Data);
send(#proxy_socket{socket = Sock}, Data) ->
    send(Sock, Data).

%% @doc Port command to write data.
-spec(async_send(Sock :: sock(), Data :: iodata()) -> ok | {error, Reason} when
    Reason :: close | timeout | inet:posix()).
async_send(Sock, Data) when is_port(Sock) ->
    case erlang:port_command(Sock, Data, [nosuspend]) of
        true  -> ok;
        false -> {error, timeout} %%TODO: tcp window full?
    end;
async_send(Sock = #ssl_socket{ssl = SslSock}, Data) ->
    case ssl:send(SslSock, Data) of
        ok -> self() ! {inet_reply, Sock, ok}, ok;
        {error, Reason} -> {error, Reason}
    end;
async_send(#proxy_socket{socket = Sock}, Data) ->
    async_send(Sock, Data).

%% @doc Receive data.
-spec(recv(Sock, Length) -> {ok, Data} | {error, Reason} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Data   :: string() | binary(),
    Reason :: closed | inet:posix()).
recv(Sock, Length) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length);
recv(#ssl_socket{ssl = SslSock}, Length) ->
    ssl:recv(SslSock, Length);
recv(#proxy_socket{socket = Sock}, Length) ->
    recv(Sock, Length).

-spec(recv(Sock, Length, Timout) -> {ok, Data} | {error, Reason} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Timout :: timeout(),
    Data   :: string() | binary(),
    Reason :: closed | inet:posix()).
recv(Sock, Length, Timeout) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length, Timeout);
recv(#ssl_socket{ssl = SslSock}, Length, Timeout)  ->
    ssl:recv(SslSock, Length, Timeout);
recv(#proxy_socket{socket = Sock}, Length, Timeout) ->
    recv(Sock, Length, Timeout).

%% @doc Async Receive data.
-spec(async_recv(Sock, Length) -> {ok, Ref} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Ref    :: reference()).
async_recv(Sock, Length) ->
    async_recv(Sock, Length, infinity).

-spec(async_recv(Sock, Length, Timeout) -> {ok, Ref} when
    Sock    :: sock(),
    Length  :: non_neg_integer(),
    Timeout :: non_neg_integer() | infinity,
    Ref     :: reference()).
async_recv(Sock = #ssl_socket{ssl = SslSock}, Length, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    spawn(fun() -> Self ! {inet_async, Sock, Ref, ssl:recv(SslSock, Length, Timeout)} end),
    {ok, Ref};
async_recv(Sock, Length, infinity) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, -1);
async_recv(Sock, Length, Timeout) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, Timeout);
async_recv(#proxy_socket{socket = Sock}, Length, Timeout) ->
    async_recv(Sock, Length, Timeout).

%% @doc Get socket options.
-spec(getopts(sock(), [inet:socket_getopt()]) ->
    {ok, [inet:socket_setopt()]} | {error, inet:posix()}).
getopts(Sock, OptionNames) when is_port(Sock) ->
    inet:getopts(Sock, OptionNames);
getopts(#ssl_socket{ssl = SslSock}, OptionNames) ->
    ssl:getopts(SslSock, OptionNames);
getopts(#proxy_socket{socket = Sock}, OptionNames) ->
    getopts(Sock, OptionNames).

%% @doc Set socket options
-spec(setopts(sock(), [inet:socket_setopt()]) -> ok | {error, inet:posix()}).
setopts(Sock, Options) when is_port(Sock) ->
    inet:setopts(Sock, Options);
setopts(#ssl_socket{ssl = SslSock}, Options) ->
    ssl:setopts(SslSock, Options);
setopts(#proxy_socket{socket = Socket}, Options) ->
    setopts(Socket, Options).

%% @doc Get socket stats
-spec(getstat(sock(), [inet:stat_option()]) -> {ok, [{inet:stat_option(), integer()}]} | {error, inet:posix()}).
getstat(Sock, Stats) when is_port(Sock) ->
    inet:getstat(Sock, Stats);
getstat(#ssl_socket{tcp = Sock}, Stats) ->
    inet:getstat(Sock, Stats);
getstat(#proxy_socket{socket = Sock}, Stats) ->
    getstat(Sock, Stats).

%% @doc Sock name
-spec(sockname(sock()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, inet:posix()}).
sockname(Sock) when is_port(Sock) ->
    inet:sockname(Sock);
sockname(#ssl_socket{ssl = SslSock}) ->
    ssl:sockname(SslSock);
sockname(#proxy_socket{dst_addr = DstAddr, dst_port = DstPort}) ->
    {ok, {DstAddr, DstPort}}.

%% @doc Socket peername
-spec(peername(sock()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, inet:posix()}).
peername(Sock) when is_port(Sock) ->
    inet:peername(Sock);
peername(#ssl_socket{ssl = SslSock}) ->
    ssl:peername(SslSock);
peername(#proxy_socket{src_addr = SrcAddr, src_port = SrcPort}) ->
    {ok, {SrcAddr, SrcPort}}.

%% @doc Socket peercert
-spec(peercert(Sock :: sock()) -> nossl | {ok, Cert :: binary()} | {error, Reason :: term()}).
peercert(Sock) when is_port(Sock) ->
    nossl;
peercert(#ssl_socket{ssl = SslSock}) ->
    ssl:peercert(SslSock);
peercert(#proxy_socket{socket = Sock}) ->
    ssl:peercert(Sock).

%% @doc Peercert subject
-spec(peer_cert_subject(Sock :: sock()) -> undefined | binary()).
peer_cert_subject(Sock) when is_port(Sock) ->
    undefined;
peer_cert_subject(#ssl_socket{ssl = SslSock}) ->
    esockd_ssl:peer_cert_subject(ssl:peercert(SslSock));
peer_cert_subject(Sock) when ?IS_PROXY(Sock) ->
    peer_cert_common_name(Sock). %% Common Name?? PP2 will not pass subject.

%% @doc Peercert common name
-spec(peer_cert_common_name(Sock :: sock()) -> undefined | binary()).
peer_cert_common_name(Sock) when is_port(Sock) ->
    undefined;
peer_cert_common_name(#ssl_socket{ssl = SslSock}) ->
    esockd_ssl:peer_cert_common_name(ssl:peercert(SslSock));
peer_cert_common_name(#proxy_socket{pp2_additional_info = AdditionalInfo}) ->
    proplists:get_value(pp2_ssl_cn, proplists:get_value(pp2_ssl, AdditionalInfo, [])).

%% @doc Shutdown socket
-spec(shutdown(sock(), How) -> ok | {error, Reason :: inet:posix()} when
    How :: read | write | read_write).
shutdown(Sock, How) when is_port(Sock) ->
    gen_tcp:shutdown(Sock, How);
shutdown(#ssl_socket{ssl = SslSock}, How) ->
    ssl:shutdown(SslSock, How);
shutdown(#proxy_socket{socket = Sock}, How) ->
    shutdown(Sock, How).

%% @doc Function that upgrade socket to sslsocket
ssl_upgrade_fun(undefined) ->
    fun(Sock) when is_port(Sock) -> {ok, Sock} end;

ssl_upgrade_fun(SslOpts) ->
    Timeout = proplists:get_value(handshake_timeout, SslOpts, ?SSL_HANDSHAKE_TIMEOUT),
    SslOpts1 = proplists:delete(handshake_timeout, SslOpts),
    fun(Sock) when is_port(Sock) ->
        case catch ssl:ssl_accept(Sock, SslOpts1, Timeout) of
            {ok, SslSock} ->
                {ok, #ssl_socket{tcp = Sock, ssl = SslSock}};
            {error, Reason} when Reason == closed; Reason == timeout ->
                fast_close(Sock),
                {error, Reason};
            %%FIXME: ignore tls_alert?
            {error, {tls_alert, _}} ->
                fast_close(Sock),
                {error, tls_alert};
            {error, Reason} ->
                fast_close(Sock),
                {error, {ssl_error, Reason}};
            {'EXIT', Reason} -> 
                fast_close(Sock),
                {error, {ssl_failure, Reason}}
        end
    end.

gc(Sock) when is_port(Sock) ->
    ok;
%% Defined in ssl/src/ssl_api.hrl:
%% -record(sslsocket, {fd = nil, pid = nil}).
gc(#ssl_socket{ssl = {sslsocket, _, Pid}}) when is_pid(Pid) ->
    erlang:garbage_collect(Pid);
gc(#proxy_socket{socket = Sock}) ->
    gc(Sock);
gc(_Sock) ->
    ok.

