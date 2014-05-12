    -module(icmp_resend).
    -export([start/1]).

    % icmp_resend:start("eth0").
    start(Dev) ->
        {ok, Socket} = ewpcap:open(Dev, [{filter, "icmp"}]),
        resend(Socket).

    resend(Socket) ->
        {ok, Packet} = ewpcap:read(Socket),
        ok = ewpcap:write(Socket, Packet),
        resend(Socket).