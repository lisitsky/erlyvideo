%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2009 Max Lapshin
%%% @doc        FLV reader for erlyvideo
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org</a> for more information
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
-module(flv_reader).
-author('Max Lapshin <max@maxidoors.ru>').
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/flv.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("../../include/ems.hrl").

-behaviour(gen_format).
-export([init/2, read_frame/2, properties/1, seek/3, can_open_file/1, write_frame/2]).

-record(media_info, {
  reader,
  frames,
  header,
  metadata,
  duration,
  height,
  width,
  audio_codec,
  video_codec
}).


can_open_file(Name) when is_binary(Name) ->
  can_open_file(binary_to_list(Name));

can_open_file(Name) ->
  filename:extension(Name) == ".flv".


write_frame(_Device, _Frame) -> 
  erlang:error(unsupported).




%%--------------------------------------------------------------------
%% @spec ({IoModule::atom(), IoDev::iodev()}, Options) -> {ok, State} | {error,Reason::atom()}
%% @doc Read flv file and load its frames in memory ETS
%% @end 
%%--------------------------------------------------------------------
init({_Module,_Device} = Reader, _Options) ->
  MediaInfo = #media_info{reader = Reader},
  case flv:read_header(Reader) of
    {#flv_header{} = Header, Offset} -> 
      read_frame_list(MediaInfo#media_info{
          frames = ets:new(frames, [ordered_set, public]),
          header = Header}, Offset);
    eof -> 
      {error, unexpected_eof};
    {error, Reason} -> {error, Reason}           
  end.

first(_) ->
  flv:data_offset().

properties(#media_info{metadata = undefined}) -> [];
properties(#media_info{metadata = Meta}) -> Meta.

read_frame_list(#media_info{reader = Reader} = MediaInfo, Offset) ->
  {Module,Device} = Reader,
  % We need to bypass PreviousTagSize and read header.
	case flv:read_tag_header(Reader, Offset)	of
	  #flv_tag{type = metadata, size = Length, offset = BodyOffset} ->
			{ok, MetaBody} = Module:pread(Device, BodyOffset, Length),
			Meta = rtmp:decode_list(MetaBody),
			{ok, parse_metadata(MediaInfo, Meta)};
		#flv_tag{next_tag_offset = NextOffset} ->
			read_frame_list(MediaInfo, NextOffset);
    eof -> 
      {ok, MediaInfo};
    {error, Reason} -> 
      {error, Reason}
  end.

get_int(Key, Meta, Coeff) ->
  case {proplists:get_value(Key, Meta), Coeff} of
    {undefined, _} -> undefined;
    {{object, []}, _} -> undefined;
    {Value, Coeff} when is_number(Coeff) andalso is_number(Value) -> Value*Coeff;
    {Value, {M, F}} -> M:F(round(Value))
  end.

parse_metadata(MediaInfo, [<<"onMetaData">>, Meta]) ->
  ?D(Meta),
  Meta1 = lists:keydelete(<<"keyframes">>, 1, Meta),
  Meta2 = lists:keydelete(<<"times">>, 1, Meta1),
  Meta3 = lists:map(fun({Key,Value}) ->
    {erlang:binary_to_atom(Key, utf8), Value}
  end, Meta2),
  % ?D({"Metadata", get_int(<<"duration">>, Meta, 1000), Meta2}),
  MediaInfo1 = MediaInfo#media_info{
    width = case get_int(<<"width">>, Meta, 1) of
      undefined -> undefined;
      ElseW -> round(ElseW)
    end,
    height = case get_int(<<"height">>, Meta, 1) of
      undefined -> undefined;
      ElseH -> round(ElseH)
    end,
    duration = get_int(<<"duration">>, Meta, 1000),
    audio_codec = get_int(<<"audiocodecid">>, Meta, {flv, audio_codec}),
    video_codec = get_int(<<"videocodecid">>, Meta, {flv, video_codec}),
    metadata = Meta3
  },
  case proplists:get_value(<<"keyframes">>, Meta) of
    {object, Keyframes} ->
      Offsets = proplists:get_value(filepositions, Keyframes),
      Times = proplists:get_value(times, Keyframes),
      insert_keyframes(MediaInfo1, Offsets, Times);
    _ -> MediaInfo1
  end;

parse_metadata(MediaInfo, Meta) ->
  ?D({"Unknown metadata", Meta}),
  MediaInfo.


insert_keyframes(MediaInfo, [], _) -> MediaInfo;
insert_keyframes(MediaInfo, _, []) -> MediaInfo;
insert_keyframes(#media_info{frames = FrameTable} = MediaInfo, [Offset|Offsets], [Time|Times]) ->
  ets:insert(FrameTable, {round(Time*1000), round(Offset)}),
  insert_keyframes(MediaInfo, Offsets, Times).


seek(#media_info{frames = FrameTable}, before, Timestamp) ->
  TimestampInt = round(Timestamp),
  Ids = ets:select(FrameTable, ets:fun2ms(fun({FrameTimestamp, Offset} = _Frame) when FrameTimestamp =< TimestampInt ->
    {Offset, FrameTimestamp}
  end)),

  case lists:reverse(Ids) of
    [Item | _] -> Item;
    _ -> undefined
  end;

seek(#media_info{frames = FrameTable}, 'after', Timestamp) ->
  TimestampInt = round(Timestamp),
  Ids = ets:select(FrameTable, ets:fun2ms(fun({FrameTimestamp, Offset} = _Frame) when FrameTimestamp >= TimestampInt ->
    {Offset, FrameTimestamp}
  end)),

  case Ids of
    [Item | _] -> Item;
    _ -> undefined
  end.


% Reads a tag from IoDev for position Pos.
% @param IoDev
% @param Pos
% @return a valid video_frame record type

read_frame(Media, undefined) ->
  read_frame(Media, first(Media));

read_frame(#media_info{reader = Reader}, Offset) ->
  flv:read_frame(Reader, Offset).

