-module(actordb_core).
-compile(export_all).
-include("actordb.hrl").
-include_lib("kernel/include/file.hrl").

% manually closes all open db handles
stop() ->
	% Artificially increase callcount so it never reaches lower than high watermark
	% Wait untill call size is 0, which will mean all requests have been handled.
	actordb_backpressure:inc_callcount(1000000),
	% Max wait 30s
	wait_done_queries(30000),
	application:stop(actordb_core).
stop_complete()	 ->
	case ets:info(bpcounters,size) == undefined of
		true ->
			ok;
		_ ->
			stop()
	end,
	init:stop().

wait_done_queries(N) when N < 0 ->
	ok;
wait_done_queries(N) ->
	case actordb_backpressure:call_size() of
		0 ->
			case [ok || {_,true} <- actordb_local:get_mupdaters_state()] of
				[] ->
					[spawn(fun() -> gen_server:call(Pid,stop) end) || {_,Pid} <- distreg:processes()],
					timer:sleep(1000),
					?AINF("All requests done."),
					ok;
				_ ->
					timer:sleep(100),
					wait_done_queries(N-100)
			end;
		X ->
			?AINF("Waiting for requests to finish. ~p bytes to go.~n",[X]),
			timer:sleep(100),
			wait_done_queries(N-100)
	end.

wait_distreg_procs() ->
	case distreg:processes() of
		[] ->
			ok;
		_ ->
			timer:sleep(1000),
			wait_distreg_procs()
	end.

start_ready() ->
	?AINF("Start ready."),
	application:set_env(actordb_core,isready,true),
	case application:get_env(actordb_core,mysql_protocol) of
		undefined ->
			ok;
		{ok, Port} ->
			case Port > 0 of
				true ->
					Ulimit = actordb_local:ulimit(),
					case ok of
						_ when Ulimit =< 256 ->
							MaxCon = 8;
						_ when Ulimit =< 1024 ->
							MaxCon = 64;
						_  when Ulimit =< 1024*4 ->
							MaxCon = 128;
						_ ->
							MaxCon = 1024
					end,
					case ranch:start_listener(myactor, 20, ranch_tcp, [{port, Port},{max_connections,MaxCon}], myactor_proto, []) of
						{ok, _} ->
							ok;
						{error,already_started} ->
							ok;
						Err ->
							?AERR("Unable to start ranch ~p",[Err])
					end,
					ok;
				false ->
					ok
			end
	end.

prestart() ->
	application:ensure_all_started(lager),
	application:ensure_all_started(sasl),
	application:ensure_all_started(os_mon),
	application:ensure_all_started(yamerl),
	application:set_env(bkdcore,usesharedstate,false),
	case catch actordb_conf:paths() of
		[_|_] ->
			ok;
		_ ->
			[Name1|_] = string:tokens(butil:tolist(node()),"@"),
			Name = butil:tobin(Name1),
			?AINF("Starting actordb"),
			Args = init:get_arguments(),
			?AINF("Starting actordb ~p ~p",[butil:ds_val(config,Args),file:get_cwd()]),
			% Read args file manually to get paths for state.
			case butil:ds_val(config,Args) of
				undefined ->
					?AERR("No app.config file in parameters! ~p",[init:get_arguments()]),
					init:stop();
				Cfgfile ->
					case catch file:consult(Cfgfile) of
						{ok,[L]} ->
							ActorParam = butil:ds_val(actordb_core,L),
							[Main,Extra,Level,_Journal,Sync,NumMngrs,QueryTimeout1] = 
								butil:ds_vals([main_db_folder,extra_db_folders,level_size,
													journal_mode,sync,num_transaction_managers,query_timeout],ActorParam,
												["db",[],0,wal,0,12,60000]),
							case QueryTimeout1 of
								0 ->
									QueryTimeout = infinity;
								QueryTimeout ->
									ok
							end,
							application:set_env(actordb_core,num_transaction_managers,NumMngrs),
							Statep = butil:expand_path(butil:tolist(Main)),
							?AINF("State path ~p, ~p",[Main,Statep]),
							% No etc folder. config files are provided manually.
							BkdcoreParam = butil:ds_val(bkdcore,L),
							case butil:ds_val(etc,BkdcoreParam) of
								undefined ->
									application:set_env(bkdcore,etc,none);
								_ ->
									ok
							end,
							case application:get_env(bkdcore,statepath) of
								{ok,_} ->
									ok;
								_ ->
									application:set_env(bkdcore,statepath,Statep)
							end,
							actordb_util:createcfg(Main,Extra,Level,wal,butil:tobin(Sync),QueryTimeout,Name);
						Err ->
							?AERR("Config invalid ~p~n~p ~p",[init:get_arguments(),Err,Cfgfile]),
							init:stop()
					end
			end,
			% Ensure folders exist.
			[begin
				case filelib:ensure_dir(F++"/actors/") of
					ok ->
						ok;
					Errx1 ->
						throw({path_invalid,F++"/actors/",Errx1})
				end,
				case  filelib:ensure_dir(F++"/shards/") of
					ok -> 
						ok;
					Errx2 ->
						throw({path_invalid,F++"/shards/",Errx2})
				end
			 end || F <- actordb_conf:paths()],

			% Start dependencies
			application:start(esqlite),
			case length(actordb_conf:paths())*2 >= erlang:system_info(logical_processors) of
				true ->
					NProcs = length(actordb_conf:paths())*2;
				false ->
					NProcs = length(actordb_conf:paths())
			end,
			esqlite3:init(NProcs),
			emurmur3:init()
	end.

start() ->
	?AINF("Starting actordb"),
	application:start(actordb_core).

start(_Type, _Args) ->
	prestart(),
	bkdcore:start(actordb:configfiles()),
	butil:wait_for_app(bkdcore),

	case file:read_file_info([actordb_sharedstate:cb_path(undefined,undefined,undefined),
								butil:tolist(?STATE_NM_GLOBAL),".",butil:tolist(?STATE_TYPE)]) of
		{ok,I} when I#file_info.size > 0 ->
			StateStart = normal;
		_I ->
			case butil:readtermfile([bkdcore:statepath(),"/stateglobal"]) of
				{_,[_|_] = State} ->
					Nodes = butil:ds_val({bkdcore,master_group},State),
					case lists:member(actordb_conf:node_name(),Nodes) of
						true ->
							StateStart = normal;
						false ->
							StateStart = wait
					end;
				_ ->
					StateStart = wait
			end
	end,

	Res = actordb_sup:start_link(),

	?AINF("Starting sharedstate type ~p",[StateStart]),
	case StateStart of
		normal ->
			actordb_sharedstate:start(?STATE_NM_GLOBAL,?STATE_TYPE,[{slave,false},create]);
		wait ->
			actordb_sharedstate:start_wait(?STATE_NM_GLOBAL,?STATE_TYPE)
	end,

	Res.

stop(_State) ->
	ok.

