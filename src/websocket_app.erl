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

%% API.
-export([start/2, stop/1, dir_loop/0, file_loop/0, file_prep/0, read_loop/0]).

%% API.
start(_Type, _Args) ->
	ets:new(dir_tab, [public, named_table]),
	ets:new(file_tab, [public, named_table]),
	ets:new(files, [public, named_table]),
	ets:insert(dir_tab, {file, "file"}),
	ets:insert(file_tab, {current_file, ""}),
	register(dir_loop, spawn(fun() -> dir_loop() end)),
	register(file_loop, spawn(fun() -> file_loop() end)),


	
	
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
		after 10000 ->
			ets:match_delete(dir_tab, '_'),
			Names = cmd:run("dir.bat",5000),
			{ok, A} = file:read_file("dir.bat"),
			case ets:info(files, size) of
				0 ->	
					filelib:fold_files( "c:/folder1",
								".*",
								true,
								fun(File2, Acc) ->
									io:format("Files ~p~n", [File2]), 
									ets:insert(files, {File2, none}),
									[File2|Acc]
					end, []);
				NumFiles ->
					io:format("No re-read dir, because files in work: ~p~n", [NumFiles])
			end,

			B = erlang:binary_to_list(A),
			Dir = string:substr(B, string:str(B,"dir") + 4, string:str(B,"/b") - string:str(B,"dir") - 5),
			%%io:format("Files string: ~p~p~p~n", string:tokens(Names,"\r\n")),
			lists:foldl(fun(File,AccIn) ->
          		ets:insert(dir_tab, {AccIn, File}),
				file_loop ! {AccIn, File, Dir},
            	io:format("Key inserted: ~p acc is ~p~n",[File,AccIn]),
				AccIn + 1
     			end, 1 , string:tokens(Names,"\r\n")),
			dir_loop()
	end.

%%ets:select(files, ['_',[],[true]]).
%%	ets:match(files, {'$1',none},1).
%% ets:match(files, '$1').
%% Preparation to put file into work.
%% Check it if it is not in process now. 
%% If all good, put it in ets table and send {filename, FileName, Dir} to file_prep function.
file_loop() ->
	receive
		stop ->
			void;
		{1, FileName, Dir} ->

			%%{[[Fi]],_} = ets:match(files, {'$1',none},1),
			%%io:format("Fi: ~p~n", [Fi]),
			%%ets:insert(files, {Fi,ttt}),

			ets:insert(file_tab, {filename_buffer, FileName}),
			[{current_file,Current_file}] = ets:lookup(file_tab, current_file),
			case Current_file of
				"" ->
					io:format("Change current_file to: ~p~n", [FileName]),
					ets:insert(file_tab, {current_file, FileName}),
					register(file_prep, spawn(fun() -> file_prep() end)),
					file_prep ! {filename, FileName, Dir};
				_ ->
					io:format("Current_file in work: ~p~n", [Current_file])
			end,
			file_loop()
	end.

%% Trying to open file, lock file, get the file properties. 
%% If good then send some data through data socket and spawn read_loop function for this file.
file_prep() ->
	receive
		stop ->
			exit(omg);
		{filename, File, Dir} ->
			Filesize = case file:read_file_info(Dir ++ "\\" ++ File) of
				{ok, Data} ->
					io:format("Success read file_info: ~p Size: ~p~n", [Dir ++ "\\" ++ File, Data#file_info.size]),
					Data#file_info.size;
				{error, Error} ->
					io:format("Error read file_info: ~p. Error: ~p~n", [Dir ++ "\\" ++ File, Error]),
					file_prep()
			end,
			case gen_udp:open(11111, [binary,{active, false}]) of
				{ok, CtrlSocket} ->
					io:format("Success open 'start' control socket ~p~n",[CtrlSocket]),
					gen_udp:send(CtrlSocket,"1.2.4.133",11111,term_to_binary({File,Filesize})),
					gproc:send({p,l, ws},{self(),ws,"filename " ++ io_lib:format("~p",[File])}),
					gproc:send({p,l, ws},{self(),ws,"size " ++ io_lib:format("~p",[Filesize])}),
					gen_udp:close(CtrlSocket);
				{error, Reason} ->
					io:format("Error open control socket ~p~n",[Reason])
			end,

			register(read_loop, spawn(fun() -> read_loop() end)),
			read_loop ! {start,Dir,File};
		Any ->
			io:format("file_work error... ~p~n",[Any])
	end.


read_loop() ->
	receive
		{start,Dir,File} ->
			Device = case file:open(Dir ++ "\\" ++ File, [read,raw,binary]) of
						{ok, D} ->
							D;
						{error, Err} ->
							io:format("Error open fileXXX: ~p~n",[Err]),
							ets:insert(file_tab, {current_file, ""}),
							exit(cant_open_file)
						end,
			{ok, Socket} = gen_udp:open(11112, [binary,{active, false}]),
			io:format("Success open data socket: ~p~n",[Socket]),
			Digest = erlang:md5_init(),
			case file:read(Device, 1024) of
				{ok, Data} -> 
				%%	io:format("Send data sock~p~n",[Data]),
					read_loop ! {{ok,Data},Device,Digest,Socket},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							Context = erlang:md5_final(Digest),
							case gen_udp:open(11111, [binary,{active, false}]) of
								{ok,CtrlSocket} ->
									io:format("Success open 'end' control socket ~p~n",[CtrlSocket]),
									gen_udp:send(CtrlSocket,"1.2.4.133",11111,Context),
									gproc:send({p,l, ws},{self(),ws,"Empty file"}),
									gen_udp:close(CtrlSocket);
							{error, Reason} ->
									io:format("Error open control socket ~p~n",[Reason]),
									exit(soket_bad)
							end,							
							ets:insert(file_tab, {current_file, ""}),
							io:format("Success close empty file: ~n");
						{error, Reason} ->
							io:format("Error close empty file: ~p~n", [Reason]),
							exit(file_error)
					end,
					
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close empty socket: ~p~n",[Socket]);
						Any ->
							io:format("Error close empty socket: ~p~n",[Any])
					end;
				{error, Error} -> 
					io:format("Error1 read file: ~p~n", [Error]),
					ets:insert(file_tab, {current_file, ""}),
					exit(read_error);
				Any -> 
					io:format("Oops1: ~p~n", [Any]),
					ets:insert(file_tab, {current_file, ""}),
					exit(oops)
			end;			
		{{ok, Bin},Device,Digest,Socket} ->
			NewDigest = erlang:md5_update(Digest, Bin),
			gproc:send({p,l, ws},{self(),ws,"1024"}),
			gen_udp:send(Socket,"1.2.4.133",11112,Bin),
			case file:read(Device, 1024) of
				{ok, Data} -> 
					read_loop ! {{ok,Data},Device,NewDigest,Socket},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							Context = erlang:md5_final(NewDigest),
							case gen_udp:open(11111, [binary,{active, false}]) of
								{ok,CtrlSocket} ->
									io:format("Success open 'end' control socket ~p~n",[CtrlSocket]),
									gen_udp:send(CtrlSocket,"1.2.4.133",11111,Context),
									gproc:send({p,l, ws},{self(),ws,"md5 " ++ io_lib:format("~p",[Context])}),
									gen_udp:close(CtrlSocket);
								{error, Reason} ->
									io:format("Error open control socket ~p~n",[Reason]),
									exit(socket_bad)
							end,
							ets:insert(file_tab, {current_file, ""}),
							io:format("Success close file, md5 is: ~s~n",[hexstring(Context)]);
						{error, Reason} ->
							io:format("Error close file: ~p~n", [Reason]),
							exit(error_eof)
					end,
					
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close data socket: ~p~n",[Socket]);
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
		Any ->
			io:format("read_loop error: ~p~n",[Any]),
			exit(read_loop_error)
	end.

hexstring(<<X:128/big-unsigned-integer>>) -> lists:flatten(io_lib:format("~32.16.0b", [X])).

stop(_State) ->
	ok.