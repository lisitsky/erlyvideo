%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        Helper module for some generic things.
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlyvideo is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlyvideo is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlyvideo.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(ems).
-author('Max Lapshin <max@maxidoors.ru>').

-export([get_var/2, get_var/3, check_app/3, try_method_chain/3, respond_to/3]).
-export([host/1]).

-export([expand_tuple/2, tuple_find/2, element/2, setelement/3]).
-export([str_split/2]).

-export([rebuild/0, restart/0]).

-export([list_by/1, top_info/1, top_info/2]).

rebuild() -> erlyvideo:rebuild().
restart() -> erlyvideo:restart().

 

list_by(What) ->
  Processes = [{Pid,erlang:element(2,erlang:process_info(Pid,What))} || Pid <- erlang:processes()],
  lists:sort(fun({_Pid1,Info1}, {_Pid2,Info2}) ->
    Info1 > Info2
  end, Processes).
  
  
top_info(What) -> top_info(What, 10).

top_info(What, Count) ->
  Top = lists:sublist(list_by(What), Count),
  [process_info(Pid,[memory,status,messages,links,
   reductions,total_heap_size,
   stack_size,suspending,dictionary,priority,initial_call,
   current_function,message_queue_len,garbage_collection]) || {Pid,_} <- Top].


expand_tuple(Tuple, 0) -> Tuple;
expand_tuple(Tuple, N) when size(Tuple) < N ->
  expand_tuple(erlang:append_element(Tuple, undefined), N);

expand_tuple(Tuple, _N) -> Tuple.

tuple_find(Tuple, Term) -> tuple_find(Tuple, Term, 1).

tuple_find(Tuple, _Term, N) when size(Tuple) < N -> false;
tuple_find(Tuple, Term, N) when erlang:element(N, Tuple) == Term -> {N, Term};
tuple_find(Tuple, Term, N) -> tuple_find(Tuple, Term, N+1).
	

element(0, _)	-> undefined;
element(N, Tuple) when size(Tuple) < N -> undefined;
element(N, Tuple) -> erlang:element(N, Tuple).

setelement(0, Tuple, _) -> Tuple;
setelement(N, Tuple, Term) ->
  Tuple1 = expand_tuple(Tuple, N),
  erlang:setelement(N, Tuple1, Term).
	
%%--------------------------------------------------------------------
%% @spec (Opt::atom(), Default::any()) -> any()
%% @doc Gets application enviroment variable. Returns Default if no 
%% varaible named Opt is found. User defined varaibles in .config file
%% override application default varabiles.
%% @end 
%%--------------------------------------------------------------------
get_var(Opt, Default) ->
	case application:get_env(erlyvideo, Opt) of
	{ok, Val} -> Val;
	_ ->
		case init:get_argument(Opt) of
		{ok, [[Val | _] | _]} -> Val;
		error		-> Default
		end
	end.


get_var(Key, Host, Default) ->
  case ets:match_object(vhosts, {{host(Host), Key}, '$1'}) of
    [{{_Hostname, Key}, Value}] -> Value;
    [] -> Default
  end.


respond_to(Module, Command, Arity) ->
  case code:ensure_loaded(Module) of
		{module, Module} -> 
		  lists:member({Command, Arity}, Module:module_info(exports));
		_ -> false
	end.
  
  
host(Hostname) when is_binary(Hostname) -> host(binary_to_list(Hostname));
host(Hostname) when is_atom(Hostname) -> Hostname;
host(FullHostname) ->
  Hostname = hd(string:tokens(FullHostname, ":")),
  case ets:match_object(vhosts, {Hostname, '$1'}) of
    [{Hostname, Host}] -> Host;
    [] -> default
  end.
  



%%--------------------------------------------------------------------
%% @spec (Opt::atom(), Command::atom(), Arity::integer()) -> any()
%% @doc Try to launch methods one by one in modules
%% @end 
%%--------------------------------------------------------------------

try_method_chain(Host, Method, Args) when is_atom(Host) ->
  try_method_chain(ems:get_var(modules, Host, [trusted_login]), Method, Args);

try_method_chain([], _Method, _Args) ->
  {unhandled};

try_method_chain([Module | Modules], Method, Args) ->
  case respond_to(Module, Method, length(Args)) of
    true -> 
      case apply(Module, Method, Args) of
        {unhandled} -> try_method_chain(Modules, Method, Args);
        Else -> Else
      end;
    false -> 
      case respond_to(Module, rtmp_method_missing, length(Args)) of
        true -> 
          case apply(Module, rtmp_method_missing, Args) of
            {unhandled} -> try_method_chain(Modules, Method, Args);
            Else -> Else
          end;
        false -> try_method_chain(Modules, Method, Args)
      end
  end.  


%%--------------------------------------------------------------------
%% @spec (Opt::atom(), Command::atom(), Arity::integer()) -> any()
%% @doc Look whan module in loaded plugins can handle required method
%% @end 
%%--------------------------------------------------------------------

check_app([], _Command, _Arity) ->
  unhandled;

check_app([Module | Applications], Command, Arity) ->
  case respond_to(Module, Command, Arity) of
    true -> {Module, Command};
    false -> 
      case respond_to(Module, rtmp_method_missing, Arity) of
        true -> {Module, rtmp_method_missing};
        false -> check_app(Applications, Command, Arity)
      end
  end;


check_app(Host, Command, Arity) ->
  Modules = ems:get_var(modules, Host, [trusted_login]),
  check_app(Modules, Command, Arity).


str_split(String, Delim) ->
  str_split(String, Delim, []).

str_split([], _, Acc) ->
  lists:reverse([[]|Acc]);

str_split(String, Delim, Acc) ->
  case string:str(String, Delim) of
    0 -> lists:reverse([String|Acc]);
    N -> 
      str_split(string:substr(String, N+1), Delim, [string:substr(String,1,N-1)|Acc])
  end.


%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").
	
str_split1_test() ->
  ?assertEqual(["http:","","ya.ru"], str_split("http://ya.ru", "/")).

str_split2_test() ->
  ?assertEqual(["http:","","ya.ru", ""], str_split("http://ya.ru/", "/")).

