    -module(test).
    -export([start/1,recv/2]).

    % icmp_resend:start("eth0").
    start(Dev) ->
        gen_udp:open(11112, [binary,{active, false},{reuseaddr,true},{recbuf,1638400}]),
        gen_udp:open(11111, [binary,{active, false},{reuseaddr,true},{recbuf,1638400}]),
        Pid1 = spawn(?MODULE,recv,[1,111]),
        Pid1 ! {start,Dev}.

    recv(Seq,P) ->
        receive
            {ewpcap, _Ref, _DatalinkType, _Time, _Length, _Packet} ->
                io:format("Seq ~p Stat ~p~n",[Seq,ewpcap:stats(P)]),
                recv(Seq+1,P);
            {start,Dev} ->
                {ok,X}=ewpcap:open(Dev, [{buffer, 67107840},{filter, "udp"}]),
                recv(1,X);
            Any ->
                io:format("TTT ~p~n",[Any])
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


