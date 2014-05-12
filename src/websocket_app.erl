%% Feel free to use, reuse and abuse the code in this file.
%%
%%
%% @PRIVATE

-module(websocket_app).
-behaviour(application).
-include_lib("kernel/include/file.hrl").
-include_lib("pkt/include/pkt.hrl").
-include_lib("eunit/include/eunit.hrl").


-define(ControlPort, 11111).
-define(DstIp, "10.241.26.60").
-define(AvailablePorts, [11112,11113,11114,11115,11116]).
-define(PacketSize, 1408).
-define(ToDoFolder,"c:/f1").
-define(CompletedFolder,"c:/f2").
-define(Pushups, 768).
-define(RestForPushups,500).

-export([start/2, stop/1, dir_loop/0, file_loop/0, zero_fill/2, file_prep/0, read_loop/0, overhead/2, move_and_clean/1, send_chunk/3]).

%% API.
start(_Type, _Args) ->
	ets:new(files, [public, named_table]),
	ets:new(program, [public, named_table]),
	register(dir_loop, spawn(fun() -> dir_loop() end)),
	register(file_loop, spawn(fun() -> file_loop() end)),
	case gen_udp:open(?ControlPort, [binary,{active, false}]) of
		{ok, CtrlSocket} ->
			ets:insert(program, {data,{coontrol_socket,CtrlSocket}}),
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
		stop ->
			void;
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
		stop ->
			void
		after 1000 ->
			case ets:match(files, {'$1',{status, none}},1) of
				{[[File]],_} ->
					io:format("Start preparation for file: ~p~n", [File]),
					ets:insert(files, {File,{status, preparation}}),
					Pid = spawn(fun() -> file_prep() end),
					Pid ! {filename, File};
				_ ->
					void
			end,
			%% io:format("File table content: ~p~n",[ets:match(files, '$1')]),
			%%ets:insert(files, {Fi,ttt}),
			file_loop()
end.

%% Point: Spawn read_loop fun, and before this, look over nonbusy ports
%% Awarness: Posible delay queue on busy ports
file_prep() ->
	receive
		stop ->
			exit(omg);
		{filename, File} ->
			Pid = spawn(fun() -> read_loop() end),
			lists:foreach(fun(E) -> E end, 
			lists:takewhile(fun(E) -> case gen_udp:open(E, [binary,{active, false},{sndbuf, 16438000}]) of 
											{ok, Socket} ->
												io:format("Success test socket with port: ~p~n",[E]),
												gen_udp:close(Socket),
												ets:insert(files, {File,{status,reading},{pid,Pid},{port,E}}),
												Pid ! {start,File},
												false;
											{error, Reason} ->
												io:format("Could not open port: ~p, reason: ~p~n",[E,Reason]),
												true;
											_ ->
												true
										end
				 						end, ?AvailablePorts));
		Any ->
			io:format("file_work error... ~p~n",[Any])
	end.
%% Point: Send chunk of file through udp and then close and others...
%% Awarness: Selfexit from fun on error opening file, for delay them
read_loop() ->
	receive
		{ok,Device,CRC,Socket,Port,Sequence,Ss} ->
			case file:read(Device, ?PacketSize) of
				{ok, Data} -> 
					NewSequence = Sequence + 1,
					case 0 =:= NewSequence rem ?Pushups of
						true ->
							timer:sleep(?RestForPushups);
						_ ->
							void
					end,
					NewCRC = erlang:crc32(CRC, Data),
					{ok, OverHead} = overhead(NewSequence,NewCRC),
					%% gproc:send({p,l, Port},{self(),Port, integer_to_list(?PacketSize)}),
					%% gen_udp:send(Socket,?DstIp,Port,<<OverHead/binary,Data/binary>>),
					K1 = [erlang:list_to_integer(K, 16) || K <- ["8c","89","a5","c7","f9","14","8c","89","a4","32","4d","d7","08","00","45","00","00","3c","0e","ec","00","00","80","11","e1","89","0a","f1","1a","1e","0a","f1","1a","3c","2b","68","2b","68","00","08","ba","bf"]],
					ewpcap:write(Ss, [K1,<<OverHead/binary,Data/binary>>]),
					self() ! {ok,Device,NewCRC,Socket,Port,NewSequence,Ss},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
							%% io:format("Close file.~n"),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ok = move_and_clean(FileToClose),
									io:format("Success close file, checksum is: ~p~n",[CRC]),
									Info2 = erlang:iolist_to_binary([<<"0">>,zero_fill(erlang:size(unicode:characters_to_binary(FileToClose,unicode)),3),unicode:characters_to_binary(FileToClose,unicode),zero_fill(erlang:size(erlang:integer_to_binary(CRC)),12),erlang:integer_to_binary(CRC)]), 
									gen_udp:send(CtrlSocket,?DstIp,?ControlPort,Info2),
									io:format("Success close~p~n",[ewpcap:stats(Ss)]),
									%% gproc:send({p,l, ws},{self(),ws,"checksum " ++ io_lib:format("~p",[CRC])}),
									%% gproc:send({p,l, 11112},{self(),11112,"checksum " ++ io_lib:format("~p",[CRC])});
									%% gproc:send({p,l,Port},{self(),Port, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[CRC])}),
									gproc:send({p,l,ws},{self(),ws, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[CRC])});
								['$end_of_table'] ->
									io:format("Error. No file to close.~n")
							end;
						AnyFileErr ->
							io:format("Error close file: ~p~n", [AnyFileErr]),
							exit(error_eof)
					end,
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close data socket: ~p~n",[Socket]),
							exit(all_good);
						AnyUdpErr ->
							io:format("Error close data socket: ~p~n",[AnyUdpErr])
					end;
				ReadError -> 
					 io:format("Error reading: ~p~n", [ReadError]),
					 exit(read_error)
			end;
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
			case file:read(Device, 8192) of
				{ok, ChunkData} -> 
					[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
					[{_, {status,reading},{pid,_},{port,Port}}] = ets:lookup(files,File),
					{ok, Socket} = gen_udp:open(Port, [binary,{active, false},{sndbuf, 99438000}]),
					Info = erlang:iolist_to_binary([<<"1">>,zero_fill(erlang:size(unicode:characters_to_binary(File,unicode)),3),unicode:characters_to_binary(File,unicode),zero_fill(erlang:size(erlang:integer_to_binary(Filesize)),12),erlang:integer_to_binary(Filesize),erlang:integer_to_binary(Port)]), 
					gen_udp:send(CtrlSocket,?DstIp,?ControlPort,Info),
					timer:sleep(500),
					io:format("Info ~p~n",[Info]),
					gproc:send({p,l, ws},{self(),ws,"file " ++ io_lib:format("~p",[File])}),
					gproc:send({p,l, ws},{self(),ws,"size " ++ io_lib:format("~p",[Filesize])}),
					gproc:send({p,l, ws},{self(),ws,"port " ++ io_lib:format("~p",[Port])}),
					spawn(?MODULE, send_chunk,[ChunkData,Port,self()]);
				eof ->
					case file:close(Device) of
						ok ->
							gen_udp:send(CtrlSocket,?DstIp,?ControlPort,"empty"),
							gproc:send({p,l, ws},{self(),ws,"Empty file"}),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ok = move_and_clean(FileToClose),
									io:format("Success close empty file.~n");
								['$end_of_table'] ->
									io:format("Error. No empty file to close.~n"),
									exit(file_read_algoritm_error)
							end;
						FileCloseError ->
							io:format("Error. Can't close empty file ~p Error: ~p~n",[File, FileCloseError]),
							ets:delete(files,File),
							exit(file_close_error)
					end,		
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close empty socket: ~p~n",[Socket]);
						UdpCloseError ->
							io:format("Error close empty socket: ~p~n",[UdpCloseError])
					end;
				FileReadError ->
					case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
						{[[FileToClose]],_} ->
							ets:delete(files,FileToClose),
							io:format("Read Error: ~p~n", [FileReadError]);
						['$end_of_table'] ->
							io:format("Error. No empty file to close.~n")
					end,
					exit(file_read_error)
			end,
			
			read_loop;
		{done,Pid} ->
			io:format("Done~p~n",[Pid]);		
		UnknownData ->
			io:format("Algorithm read_loop unknown data: ~p~n",[UnknownData]),
			%%exit(read_loop_error)
			read_loop()
	end.

overhead(NewSequence,NewCRC) ->
	OverHeadSequence = zero_fill(NewSequence,8), 
	OverHeadCRC = erlang:integer_to_binary(NewCRC),
	OverHeadCRCsize = erlang:integer_to_binary(erlang:iolist_size(OverHeadCRC)),
	case {erlang:iolist_size(OverHeadCRC) =< 9} of
		{true} ->
			OverHead = <<OverHeadSequence/binary,<<"0">>/binary, OverHeadCRCsize/binary, OverHeadCRC/binary>>;
		{false} ->
			OverHead = <<OverHeadSequence/binary,OverHeadCRCsize/binary, OverHeadCRC/binary>>
	end,
	%% io:format("Send data...~p~n",[OverHead]),
	{ok,OverHead}.

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

send_chunk(Data,Port,Pid) ->
		{ok, Socket} = ewpcap:open("\\Device\\NPF_{A79E0D8C-FD36-42F4-892D-B4214EB2B9F2}", [{filter, "icmp"},{buffer, 99438000}]),
		K1 = [erlang:list_to_integer(K, 16) || K <- ["8c","89","a5","c7","f9","14","8c","89","a4","32","4d","d7","08","00","45","00","00","3c","0e","ec","00","00","80","11","e1","89","0a","f1","1a","1e","0a","f1","1a","3c","2b","68","2b","68","00","08","ba","bf"]],
		CRC = erlang:crc32(Data),
		{ok, OverHead} = overhead(1,CRC),
		[ewpcap:write(Socket,[K1,<<OverHead/binary,PieceOfSh/binary>>]) || <<PieceOfSh:1400/binary>> <= Data],
		io:format("EDone~p~n",[self()]),
		Pid ! {done,self()}.


type_of(X) when is_integer(X)   -> integer;
type_of(X) when is_binary(X)    -> binary.

stop(_State) ->
	ok.