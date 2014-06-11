-module(ws_handler_1).
-behaviour(cowboy_websocket_handler).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

init({tcp, http}, _Req, _Opts) ->
 	io:format("Init 1: ~n", []),
	gproc:reg({p,l, 1}),
	{upgrade, protocol, cowboy_websocket}.

websocket_init(_TransportName, Req, _Opts) ->
        io:format("Init 2: ~n", []),
	{ok, Req, undefined_state}.

websocket_handle({text, Msg}, Req, State) ->
	io:format("Handle data 1: ~p~n", [Msg]),
	case {text, lists:sublist(erlang:binary_to_list(Msg),1)} of
		{text, "1"} ->
			%% gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 1}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "2"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 2}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "3"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 3}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "4"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 4}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "5"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 5}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		_ ->
			{reply,	{text, << "Nothing to respond ", Msg/binary >>}, Req, State}
	end;
websocket_handle(_Data, Req, State) ->
	{ok, Req, State}.

websocket_info(Info, Req, State) ->
	%% io:format("Info 1: ~n", []),
	case Info of
		{_PID, _Ws, _Msg} ->
			{reply,{text, _Msg}, Req, State, hibernate};
		_ ->
			{ok, Req, State, hibernate}
	end.


websocket_terminate(_Reason, _Req, _State) ->
	ok.

%%gproc:send({p,l, ws},{self(),ws,"k"}).