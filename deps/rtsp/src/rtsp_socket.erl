%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        RTSP socket module
%%%
%%% 
%%% 1. connect
%%% 2. describe
%%% 3. each setup
%%% 4. play, possible Rtp-Sync
%%% 5. get each packet
%%% 6. decode
%%% 
%%% 
%%% @end
%%% @reference  See <a href="http://erlyvideo.org/rtsp" target="_top">http://erlyvideo.org</a> for common information.
%%% @end
%%%
%%% This file is part of erlang-rtsp.
%%%
%%% erlang-rtsp is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlang-rtsp is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlang-rtsp.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(rtsp_socket).
-author('Max Lapshin <max@maxidoors.ru>').
-behaviour(gen_server).

-include("log.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include_lib("erlmedia/include/sdp.hrl").
-include("rtsp.hrl").

-export([start_link/1, set_socket/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([read/2, connect/3, describe/2, setup/3, play/2]).


-export([handle_sdp/3, reply/3, save_media_info/2]).

read(URL, Options) when is_binary(URL) ->
  read(binary_to_list(URL), Options);

read(URL, Options) ->
  try read_raw(URL, Options) of
    {ok, RTSP, MediaInfo} -> {ok, RTSP, MediaInfo}
  catch
    _Class:{error,Reason} -> {error, Reason};
    exit:Reason -> {error, Reason};
    Class:Reason -> {Class, Reason}
  end.

read_raw(URL, Options) ->
  {ok, RTSP} = rtsp_sup:start_rtsp_socket(undefined),
  ConnectResult = rtsp_socket:connect(RTSP, URL, Options),
  ok == ConnectResult orelse erlang:error(ConnectResult),
  {ok, MediaInfo, Streams} = rtsp_socket:describe(RTSP, Options),
  [ok = rtsp_socket:setup(RTSP, Stream, Options) || Stream <- Streams],
  ok = rtsp_socket:play(RTSP, Options),
  {ok, RTSP, MediaInfo}.


describe(RTSP, Options) ->
  Timeout = proplists:get_value(timeout, Options, 5000)*2,
  gen_server:call(RTSP, {request, describe}, Timeout).

setup(RTSP, Stream, Options) ->
  Timeout = proplists:get_value(timeout, Options, 5000)*2,
  gen_server:call(RTSP, {request, setup, Stream}, Timeout).

play(RTSP, Options) ->
  Timeout = proplists:get_value(timeout, Options, 5000)*2,
  gen_server:call(RTSP, {request, play}, Timeout).

connect(RTSP, URL, Options) ->
  Timeout = proplists:get_value(timeout, Options, 10000)*2,
  gen_server:call(RTSP, {connect, URL, Options}, Timeout).

start_link(Callback) ->
  gen_server:start_link(?MODULE, [Callback], []).


set_socket(Pid, Socket) when is_pid(Pid), is_port(Socket) ->
  gen_tcp:controlling_process(Socket, Pid),
  gen_server:cast(Pid, {socket_ready, Socket}).


init([Callback]) ->
  {ok, #rtsp_socket{callback = Callback, timeout = ?DEFAULT_TIMEOUT}}.


%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------


handle_call({connect, _, _} = Call, From, RTSP) ->
  rtsp_inbound:handle_call(Call, From, RTSP);

handle_call({consume, _Consumer} = Call, From, RTSP) ->
  rtsp_inbound:handle_call(Call, From, RTSP);

handle_call({request, describe} = Call, From, RTSP) ->
  rtsp_inbound:handle_call(Call, From, RTSP);

handle_call({request, setup, _Num} = Call, From, RTSP) ->
  rtsp_inbound:handle_call(Call, From, RTSP);

handle_call({request, play} = Call, From, RTSP) ->
  rtsp_inbound:handle_call(Call, From, RTSP);

handle_call(Request, _From, #rtsp_socket{} = RTSP) ->
  {stop, {unknown_call, Request}, RTSP}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast({socket_ready, Socket}, #rtsp_socket{timeout = Timeout} = State) ->
  {ok, {IP, Port}} = inet:peername(Socket),
  inet:setopts(Socket, [{active, once}]),
  {noreply, State#rtsp_socket{socket = Socket, addr = IP, port = Port}, Timeout};

handle_cast(Request, #rtsp_socket{} = Socket) ->
  {stop, {unknown_cast, Request}, Socket}.


%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------


handle_info({tcp_closed, _Socket}, State) ->
  ?D({"RTSP socket closed"}),
  {stop, normal, State};

handle_info({tcp, Socket, Bin}, #rtsp_socket{buffer = Buf, timeout = Timeout} = RTSPSocket) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, handle_packet(RTSPSocket#rtsp_socket{buffer = <<Buf/binary, Bin/binary>>}), Timeout};

handle_info({'DOWN', _, process, Consumer, _Reason}, #rtsp_socket{rtp = Consumer} = Socket) ->
  ?D({"RTSP RTP process died", Consumer}),
  {stop, normal, Socket};

handle_info({'DOWN', _, process, Consumer, _Reason}, #rtsp_socket{media = Consumer} = Socket) ->
  ?D({"RTSP consumer died", Consumer}),
  {stop, normal, Socket};

handle_info(#video_frame{} = Frame, #rtsp_socket{timeout = Timeout} = Socket) ->
  {noreply, rtsp_outbound:encode_frame(Frame, Socket), Timeout};


handle_info(timeout, #rtsp_socket{frames = Frames, media = Consumer} = Socket) ->
  lists:foreach(fun(Frame) ->
    % ?D({Frame#video_frame.content, Frame#video_frame.flavor, round(Frame#video_frame.dts)}),
    Consumer ! Frame
  end, Frames),
  {stop, timeout, Socket#rtsp_socket{frames = []}};

handle_info(Message, #rtsp_socket{} = Socket) ->
  {stop, {uknown_message, Message}, Socket}.

dump_io({request, Method, URL, Headers, undefined}) ->
  HeaderS = lists:flatten([io_lib:format("~p: ~p~n", [K, V]) || {K,V} <- Headers]),
  io:format("~s ~s RTSP/1.0~n~s~n", [Method, URL, HeaderS]);

dump_io({request, Method, URL, Headers, Body}) ->
  HeaderS = lists:flatten([io_lib:format("~p: ~p~n", [K, V]) || {K,V} <- Headers]),
  io:format("~s ~s RTSP/1.0~n~s~n~s~n", [Method, URL, HeaderS, Body]);

dump_io({response, Code, Message, Headers, undefined}) ->
  HeaderS = lists:flatten([io_lib:format("~p: ~p~n", [K, V]) || {K,V} <- Headers]),
  io:format("RTSP/1.0 ~p ~s~n~s~n", [Code, Message, HeaderS]);

dump_io({response, Code, Message, Headers, Body}) ->
  HeaderS = lists:flatten([io_lib:format("~p: ~p~n", [K, V]) || {K,V} <- Headers]),
  io:format("RTSP/1.0 ~p ~s~n~s~n~s~n", [Code, Message, HeaderS, Body]).
  
-define(DUMP_REQUEST(X), dump_io(X)).
-define(DUMP_RESPONSE(X), dump_io(X)).

handle_packet(#rtsp_socket{buffer = Data} = Socket) ->
  case packet_codec:decode(Data) of
    {more, Data} ->
      Socket;
    {ok, {rtp, _Channel, _} = RTP, Rest} ->
      Socket1 = rtsp_inbound:handle_rtp(Socket#rtsp_socket{buffer = Rest}, RTP),
      handle_packet(Socket1);
    {ok, {response, _Code, _Message, Headers, _Body} = Response, Rest} ->
      ?DUMP_RESPONSE(Response),
      Socket1 = handle_response(extract_session(Socket#rtsp_socket{buffer = Rest}, Headers), Response),
      handle_packet(Socket1);
    {ok, {request, _Method, _URL, _Headers, _Body} = Request, Rest} ->
      ?DUMP_REQUEST(Request),
      Socket1 = handle_request(Request, Socket#rtsp_socket{buffer = Rest}),
      handle_packet(Socket1)
  end.


handle_response(#rtsp_socket{state = describe} = Socket, {response, _Code, _Message, Headers, Body}) ->
  Socket1 = handle_sdp(Socket, Headers, Body),
  reply_pending(Socket1#rtsp_socket{state = undefined});

handle_response(#rtsp_socket{state = play} = Socket, {response, _Code, _Message, Headers, _Body}) ->
  Socket1 = rtsp_inbound:sync_rtp(Socket, Headers),
  reply_pending(Socket1#rtsp_socket{state = undefined});

handle_response(Socket, {response, _Code, _Message, _Headers, _Body}) ->
  reply_pending(Socket).
  

reply_pending(#rtsp_socket{pending = undefined} = Socket) ->
  Socket;

reply_pending(#rtsp_socket{state = {Method, Count}} = Socket) when Count > 1 ->
  Socket#rtsp_socket{state = {Method, Count - 1}};

reply_pending(#rtsp_socket{pending = From, pending_reply = Reply} = Socket) ->
  gen_server:reply(From, Reply),
  Socket#rtsp_socket{pending = undefined, pending_reply = ok}.

handle_sdp(#rtsp_socket{} = Socket, Headers, Body) ->
  <<"application/sdp">> = proplists:get_value('Content-Type', Headers),
  MediaInfo = sdp:decode(Body),
  save_media_info(Socket, MediaInfo).

save_media_info(#rtsp_socket{} = Socket, #media_info{audio = Audio, video = Video} = MediaInfo) ->
  StreamNums = lists:seq(1, length(Audio)+length(Video)),
  % TODO: Отрефакторить это уродство
  
  {StreamInfos, AudioNum, VideoNum, ControlMap} = case {Audio, Video} of
    {[A], [V]} -> {{A, V}, 1, 2, [{proplists:get_value(control, A#stream_info.options),1}, {proplists:get_value(control, V#stream_info.options),2}]};
    {[], [V]} -> {{V}, undefined, 1, [{proplists:get_value(control, V#stream_info.options),1}]};
    {[A], []} -> {{A}, undefined, 1, [{proplists:get_value(control, A#stream_info.options),1}]}
  end,  
  % ?D({"Streams", StreamInfos, StreamNums, ControlMap}),
  Socket#rtsp_socket{rtp_streams = StreamInfos, control_map = ControlMap, pending_reply = {ok, MediaInfo, StreamNums}, audio_rtp_stream = AudioNum, video_rtp_stream = VideoNum}.





seq(Headers) ->
  proplists:get_value('Cseq', Headers, 1).
  
%
% Wirecast goes:
% 
% ANNOUNCE with SDP
% OPTIONS
% SETUP  
  


handle_request({request, 'DESCRIBE', URL, Headers, Body}, Socket) ->
  rtsp_outbound:handle_describe_request(Socket, URL, Headers, Body);


handle_request({request, 'RECORD', URL, Headers, Body}, #rtsp_socket{callback = Callback} = State) ->
  case Callback:record(URL, Headers, Body) of
    ok ->
      reply(State, "200 OK", [{'Cseq', seq(Headers)}]);
    {error, authentication} ->
      reply(State, "401 Unauthorized", [{"WWW-Authenticate", "Basic realm=\"Erlyvideo Streaming Server\""}, {'Cseq', seq(Headers)}])
  end;


handle_request({request, 'PLAY', URL, Headers, Body}, #rtsp_socket{direction = in} = State) ->
  handle_request({request, 'RECORD', URL, Headers, Body}, State);

handle_request({request, 'PLAY', URL, Headers, Body}, #rtsp_socket{} = Socket) ->
  rtsp_outbound:handle_play_request(Socket, URL, Headers, Body);

handle_request({request, 'OPTIONS', _URL, Headers, _Body}, State) ->
  reply(State, "200 OK", [{'Server', ?SERVER_NAME}, {'Cseq', seq(Headers)}, {'Public', "SETUP, TEARDOWN, PLAY, PAUSE, DESCRIBE"}]);

handle_request({request, 'ANNOUNCE', URL, Headers, Body}, Socket) ->
  rtsp_inbound:handle_announce_request(Socket, URL, Headers, Body);

handle_request({request, 'PAUSE', _URL, Headers, _Body}, #rtsp_socket{rtp = undefined} = State) ->
  reply(State, "200 OK", [{'Cseq', seq(Headers)}]);

handle_request({request, 'PAUSE', _URL, Headers, _Body}, #rtsp_socket{rtp = Consumer} = State) ->
  gen_server:call(Consumer, {pause, self()}),
  reply(State, "200 OK", [{'Cseq', seq(Headers)}]);

handle_request({request, 'SETUP', URL, Headers, Body}, #rtsp_socket{} = Socket) ->
  Transport = proplists:get_value('Transport', Headers),
  case proplists:get_value(mode, Transport) of
    'receive' -> rtsp_inbound:handle_receive_setup(Socket, URL, Headers, Body);
    _ -> rtsp_outbound:handle_play_setup(Socket, URL, Headers, Body)
  end;
  

handle_request({request, 'TEARDOWN', _URL, Headers, _Body}, #rtsp_socket{} = State) ->
  reply(State, "200 OK", [{'Cseq', seq(Headers)}]).



reply(State, Code, Headers) ->
  reply(State, Code, Headers, undefined).

reply(#rtsp_socket{socket = Socket, session = SessionId, timeout = TimeOut} = State, Code, Headers, Body) ->
  Headers2 =
    case SessionId of
      undefined -> Headers;
      _ ->
        if is_integer(TimeOut) ->
            TO = ";timeout=" ++ integer_to_list(TimeOut);
           true -> TO = ""
        end,
        [{'Session', integer_to_list(SessionId) ++ TO} | lists:keydelete('Session', 1, Headers)]
    end,
  Headers3 = case Body of
    undefined -> [{'Content-Length', 0} | Headers2];
    _ -> [{'Content-Length', iolist_size(Body)}, {'Content-Type', <<"application/sdp">>}|Headers2]
  end,
  Reply = iolist_to_binary(["RTSP/1.0 ", Code, <<"\r\n">>, packet_codec:encode_headers(Headers3), <<"\r\n">>,
  case Body of
    undefined -> <<>>;
    _ -> Body
  end]),
  io:format("[RTSP Response to Client]~n~s", [Reply]),
  gen_tcp:send(Socket, Reply),
  State.




extract_session(Socket, Headers) ->
  case proplists:get_value('Session', Headers) of
    undefined ->
      Socket;
    FullSession ->
      % ?D({"Session", FullSession}),
      Socket#rtsp_socket{session = hd(string:tokens(binary_to_list(FullSession), ";"))}
  end.




%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


