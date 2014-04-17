%% Feel free to use, reuse and abuse the code in this file.
%%
%% 11111 control socket
%% 11112 data socket
%%
%% @PRIVATE
%%  ets:match(files, '_').
%%	ets:match(files, {'$1',none},1).
%%	ets:select_count(files, ['_',[],[true]}]).
%%	ets:info(files, size).
-module(websocket_app).
-behaviour(application).
-include_lib("kernel/include/file.hrl").

-define(ControlPort, 11111).
-define(DstIp, "1.2.4.2").
-define(AvailablePorts, [11112,11113,11114,11115,11116]).
-define(PacketSize, 1408).
-define(Folder,"c:/folder1").

%% API.
-export([start/2, stop/1, dir_loop/0, file_loop/0, file_prep/0, read_loop/0]).

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

%% Trying to get list of files.
%% In Dir var we get list with format:
%% filename1.ext
%% filename2.ext
%% ...
%% Then send each filename to file_loop function
dir_loop() ->
	receive
		stop ->
			void;
		_ ->
			dir_loop()
		after 3000 ->
			case ets:info(files, size) of
				0 ->	
					NumFiles = filelib:fold_files( ?Folder,".*",true,
								fun(File2, Acc) ->
									%%io:format("Files ~p~n", [File2]), 
									ets:insert(files, {File2, {status,none}}),
									Acc + 1
					end, 0),
					io:format("Files added ~p~n", [NumFiles]);
				NumFiles ->
					io:format("No re-read dir, because files in work: ~p~n", [NumFiles])
			end,
			dir_loop()
end.

%%ets:select(files, ['_',[],[true]]).
%%	ets:match(files, {'$1',none},1).
%% ets:match(program, '$1').
%% ets:match(files, {'$1',{status,reading},{pid,'$2'}},1).
%% ets:delete_object(files,)
%% Preparation to put file into work.
%% Check it if it is not in process now. 
%% If all good, put it in ets table and send {filename, FileName, Dir} to file_prep function.

file_loop() ->
	receive
		stop ->
			void
		after 5000 ->
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
%% Trying to open file, lock file, get the file properties. 
%% If good then start sending read data through data socket and spawn read_loop function for this file.
file_prep() ->
	receive
		stop ->
			exit(omg);
		{filename, File} ->
			Filesize = case file:read_file_info(File) of
				{ok, Data} ->
					io:format("Success read file_info: ~p Size: ~p~n", [File, Data#file_info.size]),
					Data#file_info.size;
				{error, Error} ->
					io:format("Error read file_info: ~p. Error: ~p~n", [File, Error]),
					file_prep()
			end,
			Pid = spawn(fun() -> read_loop() end),
			lists:foreach(fun(E) -> E end, 
			lists:takewhile(fun(E) -> case gen_udp:open(E, [binary,{active, false}]) of 
										{ok, Socket} ->
											io:format("Success test socket with port: ~p~n",[E]),
											gen_udp:close(Socket),
											ets:insert(files, {File,{status,reading},{pid,Pid},{port,E}}),
											false;
										{error, Reason} ->
											io:format("Could not open port: ~p, reason: ~p~n",[E,Reason]),
											true;
										_ ->
											true
									end
			 						end, ?AvailablePorts)),

 			[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
			gen_udp:send(CtrlSocket,?DstIp,?ControlPort,term_to_binary({File,Filesize})),
			gproc:send({p,l, ws},{self(),ws,"file " ++ io_lib:format("~p",[File])}),
			gproc:send({p,l, ws},{self(),ws,"size " ++ io_lib:format("~p",[Filesize])}),
			Pid ! {start,File};
		Any ->
			io:format("file_work error... ~p~n",[Any])
	end.


read_loop() ->
	receive
		{ok,Device,Digest,Socket,Port} ->
			case file:read(Device, ?PacketSize) of
				{ok, Data} -> 
					NewDigest = erlang:adler32(Digest, Data),
					io:format("Send data...~n"),
					gproc:send({p,l, Port},{self(),Port, integer_to_list(?PacketSize)}),
					gen_udp:send(Socket,?DstIp,Port,Data),
					self() ! {ok,Device,NewDigest,Socket,Port},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
							io:format("Close file.~n"),
							gen_udp:send(CtrlSocket,?DstIp,?ControlPort,list_to_binary(integer_to_list(Digest))),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ets:delete(files,FileToClose),
									io:format("Success close file, checksum is: ~p~n",[Digest]),
									%% gproc:send({p,l, ws},{self(),ws,"checksum " ++ io_lib:format("~p",[Digest])}),
									%% gproc:send({p,l, 11112},{self(),11112,"checksum " ++ io_lib:format("~p",[Digest])});
									%% gproc:send({p,l,Port},{self(),Port, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[Digest])}),
									gproc:send({p,l,ws},{self(),ws, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[Digest])});
								['$end_of_table'] ->
									io:format("Error. No file to close.~n")
							end;
						{error, Reason} ->
							io:format("Error close file: ~p~n", [Reason]),
							exit(error_eof)
					end,
					
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close data socket: ~p~n",[Socket]),
							exit(all_good);
						Any ->
							io:format("Error close data socket: ~p~n",[Any])
					end;
				{error, Error} -> 
					io:format("Error2 read file: ~p~n", [Error]),
					ets:insert(file_tab, {current_file, ""}),
					exit(error_read);
				Any -> 
					 io:format("Oops2: ~p~n", [Any]),
					 ets:insert(file_tab, {current_file, ""}),
					 exit(oops2)
			end;
		{start,File} ->
			Device = case file:open(File, [read,raw,binary]) of
						{ok, D} ->
							D;
						A ->
							io:format("Error. Can't open file.~p~n",[A]),
							ets:delete(files,File),
							exit(cant_open_file)
						end,
			[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
			[{_, {status,reading},{pid,_},{port,Port}}] = ets:lookup(files,File),
			{ok, Socket} = gen_udp:open(Port, [binary,{active, false}]),
			gproc:send({p,l, ws},{self(),ws,"port " ++ io_lib:format("~p",[Port])}),
			case file:read(Device, ?PacketSize) of
				{ok, Data} -> 
					%% io:format("Send data sock~p~n",[Data]),
					Digest = erlang:adler32(Data),
					self() ! {ok,Device,Digest,Socket,Port},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
		
							gen_udp:send(CtrlSocket,?DstIp,?ControlPort,"empty"),
							gproc:send({p,l, ws},{self(),ws,"Empty file"}),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ets:delete(files,FileToClose),
									io:format("Success close empty file.~n");
								['$end_of_table'] ->
									io:format("Error. No empty file to close.~n")
							end;
						B ->
							io:format("Error. Can't close empty file.~p",[B]),
							ts:delete(files,File),
							exit(file_error)
					end,
					
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close empty socket: ~p~n",[Socket]);
						Any ->
							io:format("Error close empty socket: ~p~n",[Any])
					end;
				Any -> 
					case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
						{[[FileToClose]],_} ->
							ets:delete(files,FileToClose),
							io:format("Read Error: ~p~n", [Any]);
						['$end_of_table'] ->
							io:format("Error. No empty file to close.~n")
					end,
					exit(oops)
			end;			
		Any ->
			io:format("read_loop error: ~p~n",[Any]),
			exit(read_loop_error)
	end.

%%hexstring(<<X:128/big-unsigned-integer>>) -> lists:flatten(io_lib:format("~32.16.0b", [X])).

stop(_State) ->
	ok.