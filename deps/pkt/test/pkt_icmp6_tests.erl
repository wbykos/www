-module(pkt_icmp6_tests).

-include_lib("pkt/include/pkt.hrl").
-include_lib("eunit/include/eunit.hrl").

codec_test_() ->
    [
        decode(),
        encode()
    ].

packet() ->
    <<128,0,255,149,7,79,0,1,169,244,102,82,0,0,0,0,36,187,0,
      0,0,0,0,0,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,
      31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,
      49,50,51,52,53,54,55>>.

decode() ->
    {Header, Payload} = pkt:icmp6(packet()),
    ?_assertEqual(
        {#icmp6{type = 128,code = 0,checksum = 65429,
                un = <<0,0,0,0>>,
                pptr = 0,mtu = 0,id = 1871,seq = 1,maxdelay = 0,res = 0,
                res2 = 0,saddr = undefined,daddr = undefined,hop = 0,m = 0,
                o = 0,lifetime = 0,reach = 0,retrans = 0,r = 0,s = 0,
                delay = 0},
          <<169,244,102,82,0,0,0,0,36,187,0,0,0,0,0,0,16,17,18,19,
            20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,
            38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55>>},
        {Header, Payload}
    ).

encode() ->
    Packet = packet(),
    {Header, Payload} = pkt:icmp6(Packet),
    ?_assertEqual(Packet, <<(pkt:icmp6(Header))/binary, Payload/binary>>).
