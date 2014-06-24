%% Feel free to use, reuse and abuse the code in this file.
%%
%%
%% @PRIVATE

-module(websocket_app).
-behaviour(application).
-include_lib("kernel/include/file.hrl").



-define(ControlPort, 11111).
-define(DstIp, "10.241.26.60").
-define(PacketSize, 1328).
-define(ToDoFolder,"c:/f1").
-define(CompletedFolder,"c:/f2").
%% -define(ChunkSize,40).
-define(ChunkSize,16777216).
-define(Threads,3).
-define(Device,"\\Device\\NPF_{A79E0D8C-FD36-42F4-892D-B4214EB2B9F2}").
-define(Head,[erlang:list_to_integer(K, 16) || K <- ["8c","89","a5","c7","f9","14","8c","89","a4","32","4d","d7","08","00","45","00","00","3c","0e","ec","00","00","80","11","e1","89","0a","f1","1a","1e","0a","f1","1a","3c","2b","68","2b","68","00","08","ba","bf"]]).

%% K1 =[erlang:list_to_integer(K, 16) || K <- ["8c","89","a5","c7","f9","14","8c","89","a4","32","4d","d7","08","00","45","00","00","3c","0e","ec","00","00","80","11","e1","89","0a","f1","1a","1e","0a","f1","1a","3c","2b","68","2b","68","00","08","ba","bf"]],
-export([start/2, stop/1, dir_loop/0, file_loop/0, zero_fill/2, read_loop/0, overhead/3, move_and_clean/1, send_chunk/6,send_control/1,get_free_thread/0,send_packet/6]).

%% API.
start(_Type, _Args) ->
	ets:new(files, [public, named_table,bag]),
	ets:new(program, [public, named_table, bag]),
	register(dir_loop, spawn(fun() -> dir_loop() end)),
	register(file_loop, spawn(fun() -> file_loop() end)),
	case gen_udp:open(?ControlPort, [binary,{active, false}]) of
		{ok, CtrlSocket} ->
			ets:insert(program, {data,{coontrol_socket,CtrlSocket}}),
			lists:takewhile(fun(X) -> ets:insert(program, {data,{thread,X,free}}) end, lists:seq(1,?Threads)),
			register(send_control, spawn(?MODULE, send_control,[CtrlSocket])),
			io:format("Success open control socket ~p~n",[CtrlSocket]);
		{error, Reason} ->
			io:format("Error open control socket ~p~n",[Reason]),
			exit(socket_needed)
	end,
	
	Dispatch = cowboy_router:compile([
		{'_', [
			{"/", cowboy_static, [
				{directory, {priv_dir, websocket, []}},
				{file, <<"index.html">>},
				{mimetypes, [{<<".html">>, [<<"text/html">>]}]}
			]},
			{"/websocket", ws_handler, []},
			{"/websocket1", ws_handler_1, []},
			{"/websocket2", ws_handler_2, []},
			{"/websocket3", ws_handler_3, []},
			{"/static/[...]", cowboy_static, [
				{directory, {priv_dir, websocket, [<<"static">>]}},
				{mimetypes, [{<<".js">>, [<<"application/javascript">>]}]}
			]}
		]}
	]),
	{ok, _} = cowboy:start_http(http, 100, [{port, 80}],
		[{env, [{dispatch, Dispatch}]}]),
	websocket_sup:start_link().

%% Point: Periodic scan files in ToDoFolder
dir_loop() ->
	receive
		_ ->
			dir_loop()
		after 3000 ->
			case ets:info(files, size) of
				0 ->	
					NumFiles = filelib:fold_files( ?ToDoFolder,".*",true,
								fun(File2, Acc) ->
									%%io:format("Files ~p~n", [File2]), 
									ets:insert(files, {File2, {status,none}}),
									Acc + 1
					end, 0),
					io:format("Files added ~p~n", [NumFiles]);
				NumFiles ->
					io:format("No re-read dir, because files in work: ~p~n", [NumFiles])
			end
			%% dir_loop()
end.

%% Point: Periodic scan files in file table
file_loop() ->
	receive
		after 1000 ->
			case ets:match(files, {'$1',{status, none}},1) of
				{[[File]],_} ->
					io:format("Start reading for file: ~p~n", [File]),
					ets:delete_object(files,{File,{status,none}}),
					ets:insert(files, {File,{status,reading}}),
					Pid = spawn(fun() -> read_loop() end),
					Pid ! {start, File};
				_ ->
					void
			end,
			file_loop()
end.


%% Point: Send chunk of file through udp and then close and others...
%% Awarness: Selfexit from fun on error opening file, for delay them
read_loop() ->
	receive
		{start,File} ->
			Device = case file:open(File, [read,raw,binary]) of
						{ok, FileDevice} ->
							FileDevice;
						FileOpenError ->
							io:format("Retry. Can't open file ~p Error: ~p~n",[File, FileOpenError]),
							ets:delete(files,File),
							exit(cant_open_file)
						end,
			Filesize = case file:read_file_info(File) of
				{ok, FileData} ->
					io:format("Success read file_info: ~p Size: ~p~n", [File, FileData#file_info.size]),
					FileData#file_info.size;
				FileReadInfoError ->
					io:format("Retry. Can't read file_info: ~p Error: ~p~n", [File, FileReadInfoError]),
					ets:delete(files,File),
					exit(file_read_info_error)
			end,
			FileInfo = erlang:iolist_to_binary([<<"1">>,zero_fill(erlang:size(unicode:characters_to_binary(File,unicode)),3),unicode:characters_to_binary(File,unicode),zero_fill(erlang:size(erlang:integer_to_binary(Filesize)),12),erlang:integer_to_binary(Filesize)]), 
			io:format("Started file ~p Size ~p on pid ~p~n",[File,Filesize,self()]),
			gproc:send({p,l, ws},{self(),ws,"newfile:" ++ io_lib:format("~p",[File]) ++ io_lib:format("~p",[zero_fill(Filesize,12)]) ++ io_lib:format("~p",[zero_fill(?ChunkSize,12)]) }),
			%% gproc:send({p,l, ws},{self(),ws,"chksize:" ++ io_lib:format("~p",[?ChunkSize])}),
			send_control ! {send,FileInfo},
			self() ! {readchunk,File,Device,1,0},
			read_loop();
		{readchunk,File,Device,ChunkSeq,Offset} ->
			{ok,_Pos} = file:position(Device,Offset),
			%% io:format("Set to ~p~n",[Pos]),
			case file:read(Device, ?ChunkSize) of
				{ok, ChunkData} ->
					Thread = get_free_thread(),
					timer:sleep(500),
					io:format("Chunk beg ~p Pid: ~p Thread: ~p Offset: ~p~n",[ChunkSeq,self(),Thread,Offset]),
					gproc:send({p,l, ws},{self(),ws,"newchnk:"++io_lib:format("~p",[Thread])++"file:" ++ io_lib:format("~p",[File])}),
					%% gproc:send({p,l, ws},{self(),ws,"size " ++ io_lib:format("~p",[Filesize])}),
					%% gproc:send({p,l, ws},{self(),ws,"port " ++ io_lib:format("~p",[Port])}),
					ets:insert(files,{File,{chunk,ChunkSeq,packet,1}}),
					spawn(?MODULE, send_chunk,[File,ChunkData,Thread,ChunkSeq,Offset,self()]),
					self() ! {readchunk,File,Device,ChunkSeq+1,Offset+?ChunkSize},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							case ets:member(files, File) of
								true ->	io:format("Success close file.~p~n",[File]),ets:insert(files,{File,{status,done}}), self() ! {done,File}, read_loop();
								false -> io:format("Error. No file to close.~p~n",[File]),exit(file_read_algoritm_error)
							end;
						FileCloseError ->
							io:format("Error. Can't close file ~p Error: ~p~n",[File, FileCloseError]),
							ets:delete(files,File),
							exit(file_close_error)
					end;
				FileReadError ->
					case ets:match(files, {'$1',{status,reading}},1) of
						{[[FileToClose]],_} ->
							ets:delete(files,FileToClose),
							io:format("Read Error: ~p~n", [FileReadError]);
						['$end_of_table'] ->
							io:format("Error. No file to close.~n")
					end,
					exit(file_read_error)
			end;
		{done,File} ->
			Match1 = ets:match(files, {'$1',{status,done}}),
			Match2 = ets:match(files, {File,{chunk,'$1',packets,'_'}}),
			Match4 = ets:match(files, {File,{chunk,'$1',offset,'_'}}),
			 %% io:format("E~p ttt ~p ttt ~p~n",[Match2,lists:sort(Match4),Match1]),
				case [] =/= Match1 andalso lists:sort(Match2) == lists:sort(Match4) of
					true ->
								send_control ! {send,"File End"},
								gproc:send({p,l, ws},{self(),ws,"finfile:"++io_lib:format("~p",[File])}),
								io:format("Table ~p~n",[ets:match(files, '$1')]),
								ok = move_and_clean(File),
								io:format("Done~p~n",[File]);

					_Any ->
						%% io:format("DDDD~p~n",[Any]),
						read_loop()
				end;	
		UnknownData ->
			io:format("Read_loop unknown data: ~p~n",[UnknownData]),
			%%exit(read_loop_error)
			read_loop()
	end.

overhead(Data,File,ChunkSeq) ->
	[[NewSequence]] = ets:match(files, {File,{chunk,ChunkSeq,packet,'$1'}}),
	OverHeadSequence = zero_fill(NewSequence,8), 
	OverHeadCRC = zero_fill(erlang:crc32(Data),12),
	OverHead = <<OverHeadSequence/binary,OverHeadCRC/binary>>,
	%% io:format("Send data...~p~n",[NewSequence]),
	ets:delete_object(files,{File,{chunk,ChunkSeq,packet,NewSequence}}),
	ets:insert(files,{File,{chunk,ChunkSeq,packet,NewSequence+1}}),
	OverHead.

zero_fill(Number, Size) ->
	case type_of(Number) of
		integer ->
			B1 = erlang:integer_to_binary(Number);
		binary ->
			B1 = Number
	end,
	B2 = erlang:list_to_binary(string:copies("0",Size - erlang:size(B1))),
	B3 = <<B2/binary,B1/binary>>,
	B3.

move_and_clean(FileToClose) ->
	%% FileToMove = filename:join(lists:append([?CompletedFolder],lists:nthtail(erlang:length(filename:split(?ToDoFolder)),filename:split(FileToClose)))),
	%% filelib:ensure_dir(FileToMove),
	%% file:rename(FileToClose,FileToMove), 
	ets:delete(files,FileToClose),
	ok.
%% 
send_chunk(File,Data,Thread,ChunkSeq,Offset,Pid) ->
		%% {ok, Socket} = ewpcap:open(?Device, [{filter, "icmp"},{buffer, 32438000}]),
		io:format("Thread ~p~n",[Thread]),
		{ok, Socket2} = gen_udp:open(22220+Thread,[binary,{active, false},{buffer, 16777216},{dontroute, true},{reuseaddr, true},{sndbuf, 16777216}]),
		case erlang:size(Data) =< ?PacketSize of
			true -> Len = erlang:size(Data);
			false -> Len = ?PacketSize
		end,
		%% Len2 = Len+62,
		ets:insert(files,{File,{chunk,ChunkSeq,offset,Offset}}),
		%% CompiledData = erlang:list_to_binary([erlang:list_to_binary([?Head,erlang:list_to_binary([overhead(PieceOfSh,File,ChunkSeq),<<PieceOfSh/binary>>])]) || <<PieceOfSh:Len/binary>> <= Data]),
		%% io:format("Data Len ~p Len2 ~p HERE ~p~n",[Len,Len2,CompiledData]),
		%% [ewpcap:write(Socket,[<<PieceOfSh2/binary>>]) || <<PieceOfSh2:Len2/binary>> <= CompiledData],
		[ send_packet(Socket2,"10.241.26.60",Thread,PieceOfSh,File,ChunkSeq) || <<PieceOfSh:Len/binary>> <= Data],
		%% io:format("Chunk ~p end Pid: ~p Thread: ~p Stats: ~p~n",[ChunkSeq,self(),Thread,ewpcap:stats(Socket)]),
		%% ok = ewpcap:close(Socket),
		ok = gen_udp:close(Socket2),
		gproc:send({p,l, ws},{self(),ws,"donechk:"++io_lib:format("~p",[ChunkSeq])++"file:"++io_lib:format("~p",[File])}),
		[[SendedPackets]] = ets:match(files, {File,{chunk,ChunkSeq,packet,'$1'}}),
		ets:delete_object(files,{File,{chunk,ChunkSeq,packet,SendedPackets}}),
		ets:insert(files,{File,{chunk,ChunkSeq,packets,SendedPackets}}),
		true = ets:delete_object(program, {data,{thread,Thread,active}}),
		true = ets:insert(program, {data,{thread,Thread,free}}),
		Pid ! {done, File},
		timer:sleep(1000).

send_packet(Socket,Ip,Thread,Data,File,ChunkSeq) ->
		[[NewSequence]] = ets:match(files, {File,{chunk,ChunkSeq,packet,'$1'}}),
		ets:delete_object(files,{File,{chunk,ChunkSeq,packet,NewSequence}}),
		ets:insert(files,{File,{chunk,ChunkSeq,packet,NewSequence+1}}),
		gen_udp:send(Socket,Ip,22220+Thread,Data),
		case NewSequence rem 32 of
			0 ->
				gproc:send({p,l, Thread},{self(),Thread,io_lib:format("~p",[ChunkSeq])++io_lib:format("~p",[NewSequence*?PacketSize])});
			_ ->
				void
		end.
		


get_free_thread() ->
	Sorted = lists:sort(ets:match(program, {data,{thread,'$1',free}})),
	case Sorted =/= [] of
		true ->
			[N] = lists:nth(1,Sorted),
			case gen_udp:open(22220+N,[binary,{active, false},{dontroute, true},{reuseaddr, true}]) of
				{ok,S} ->
					gen_udp:close(S),
					ets:delete_object(program, {data,{thread,N,free}}),
					%% io:format("Sorted1 ~p~n",[ets:match(program, '$1')]),
					ets:insert(program, {data,{thread,N,active}}),
					%% io:format("Sorted2 ~p~n",[ets:match(program, '$1')]),
					N;
				{error,_} ->
					timer:sleep(500),
					get_free_thread()
			end;
		false ->
			timer:sleep(500),
			get_free_thread()
	end.

send_control(Socket) ->
	receive
		{send,Data} ->
			gen_udp:send(Socket,?DstIp,?ControlPort,Data),
			send_control(Socket)
	end.



type_of(X) when is_integer(X)   -> integer;
type_of(X) when is_binary(X)    -> binary.

stop(_State) ->
	ok.