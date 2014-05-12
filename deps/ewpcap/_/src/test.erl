    -module(test).
    -export([start/1,recv/1,recv2/1,recv3/1]).

    % icmp_resend:start("eth0").
    start(Dev) ->
        Pid1 = spawn(?MODULE,recv,[1]),
        spawn(?MODULE,recv2,[1]),
        spawn(?MODULE,recv3,[1]),
        Pid1 ! {start,Dev}.

    recv(Seq) ->
        receive
            {ewpcap, _Ref, _DatalinkType, _Time, _Length, _Packet} ->
                recv2(Seq+1),
                io:format("One ~p~n",[Seq]);
            {start,Dev} ->
               ewpcap:open(Dev, [{filter, "udp"}]),
               recv(1)
        end.

    recv2(Seq) ->
        receive
            {ewpcap, _Ref, _DatalinkType, _Time, _Length, _Packet} ->
                recv3(Seq+1),
                io:format("One ~p~n",[Seq])
    end.

    recv3(Seq) ->
        receive
            {ewpcap, _Ref, _DatalinkType, _Time, _Length, _Packet} ->
                recv(Seq+1),
                io:format("One ~p~n",[Seq])
    end.


                %% Seq1 = Seq + 1,
                %% {ok,_Packet} = ewpcap:read(Socket),
                %% %% ok = ewpcap:write(Socket, Packet),
                %% case N of 
                %%     1 -> 
                %%         io:format("Got 111 ~p~n",[Seq1]);
                %%     2 ->
                %%         io:format("Got 222 ~p~n",[Seq1]);
                %%     _ ->
                %%         io:format("Got 333 ~p~n",[Seq1])
                %% end,


