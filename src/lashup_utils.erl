%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 14. Jan 2016 8:59 PM
%%%-------------------------------------------------------------------
-module(lashup_utils).
-author("sdhillon").

%% API
-export([seed/0, shuffle_list/2, new_window/1, add_tick/1, count_ticks/1, compare_vclocks/2, get_dcos_ip/0, erlang_nodes/1, maybe_poll_for_master_nodes/0]).

-record(window, {samples = [], window_time = 0}).

seed() ->
  {erlang:phash2([node()]),
  erlang:monotonic_time(),
  erlang:unique_integer()}.


shuffle_list(List, FixedSeed) ->
  {_, PrefixedList} =
    lists:foldl(fun(X, {SeedState, Acc}) ->
      {N, SeedState1} = random:uniform_s(1000000, SeedState),
      {SeedState1, [{N, X}|Acc]}
                end,
      {FixedSeed, []},
      List),
  PrefixedListSorted = lists:sort(PrefixedList),
  [Value || {_N, Value} <- PrefixedListSorted].

new_window(WindowTime) ->
  #window{window_time = WindowTime}.

add_tick(Window = #window{window_time = WindowTime, samples = Samples}) ->
  Sample = erlang:monotonic_time(milli_seconds),
  Now = erlang:monotonic_time(milli_seconds),
  Samples1 = [Sample|Samples],
  {Samples2, _} = lists:splitwith(fun(X) -> X > Now - WindowTime end, Samples1),
  Window#window{samples = Samples2}.

count_ticks(_Window = #window{window_time = WindowTime, samples = Samples}) ->
  Now = erlang:monotonic_time(milli_seconds),
  {Samples1, _} = lists:splitwith(fun(X) -> X > Now - WindowTime end, Samples),
  length(Samples1).

compare_vclocks(V1, V2) ->
  %% V1 dominates V2
  DominatesGT = riak_dt_vclock:dominates(V1, V2),
  DominatesLT = riak_dt_vclock:dominates(V2, V1),
  Equal = riak_dt_vclock:equal(V1, V2),
  if
    DominatesGT ->
      gt;
    DominatesLT ->
      lt;
    Equal ->
      equal;
    true ->
      concurrent
  end.

get_dcos_ip() ->
  case inet:parse_ipv4_address(os:cmd("/opt/mesosphere/bin/detect_ip")) of
    {ok, IP} ->
      IP;
    {error, einval} ->
      false
  end.

maybe_poll_for_master_nodes() ->
  IPs = inet_res:lookup("master.mesos", in, a, [], 1000),
  Nodes = [erlang_nodes(IP) || IP <- IPs],
  FlattenedNodes = lists:flatten(Nodes),
  FlattenedNodesSet = ordsets:from_list(FlattenedNodes),
  FlattenedNodesSet.


erlang_nodes(IP) ->
  case net_adm:names(IP) of
    {error, _} ->
      [];
    {ok, NamePorts} ->
      IPPorts = [{IP, Port} || {_Name, Port} <- NamePorts],
      lists:foldl(fun ip_port_to_nodename/2, [], IPPorts)
  end.

%% Borrowed the bootstrap of the disterl protocol :)

ip_port_to_nodename({IP, Port}, Acc) ->
  case gen_tcp:connect(IP, Port, [binary, {packet, 2}, {active, false}], 500) of
    {error, _Reason} ->
      Acc;
    {ok, Socket} ->
      try_connect_ip_port_to_nodename(Socket, Acc)
  end.

try_connect_ip_port_to_nodename(Socket, Acc) ->
  %% The 3rd field, flags
  %% is set statically
  %% it doesn't matter too much
  Random = random:uniform(100000000),
  Nodename = iolist_to_binary(io_lib:format("r-~p@254.253.252.251", [Random])),
  NameAsk = <<"n", 00, 05, 16#37ffd:32, Nodename/binary>>,
  case gen_tcp:send(Socket, NameAsk) of
    ok ->
      Acc2 = wait_for_status(Socket, Acc),
      gen_tcp:close(Socket),
      Acc2;
    _ ->
      gen_tcp:close(Socket),
      Acc
  end.

wait_for_status(Socket, Acc) ->
  case gen_tcp:recv(Socket, 0, 1000) of
    {ok, <<"sok">>} ->
      Status = <<"sok">>,
      case gen_tcp:send(Socket, Status) of
        ok ->
          wait_for_name(Socket, Acc);
        _ ->
          Acc
      end;
    _ ->
      Acc
  end.

wait_for_name(Socket, Acc) ->
  case gen_tcp:recv(Socket, 0, 1000) of
    {ok, <<"n", _Version:16, _Flags:32, _Handshake:32, Nodename/binary>>} ->
      [binary_to_atom(Nodename, latin1)|Acc];
    _ ->
      Acc
  end.
