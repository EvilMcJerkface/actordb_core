% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
-module(actordb_sqlproc).
-behaviour(gen_server).
-define(LAGERDBG,true).
-export([start/1, stop/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([print_info/1]).
-export([read/4,write/4,call/4,call/5,diepls/2,try_actornum/3]).
-export([call_slave/4,call_slave/5,start_copylock/2]). %call_master/4,call_master/5
-export([write_call/3, write_call1/4, read_call/3, read_call1/4]).
-include_lib("actordb_sqlproc.hrl").

% Read actor number without creating actor.
try_actornum(Name,Type,CbMod) ->
	case call({Name,Type},[actornum],{state_rw,actornum},CbMod) of
		{error,nocreate} ->
			{"",undefined};
		{ok,Path,NumNow} ->
			{Path,NumNow}
	end.

read(Name,Flags,[{copy,CopyFrom}],Start) ->
	case distreg:whereis(Name) of
		undefined ->
			R = #read{sql = <<"select * from __adb limit 1;">>, flags = Flags},
			case call(Name,Flags,R,Start) of
				{ok,_} ->
					{ok,[{columns,{<<"status">>}},{row,{<<"ok">>}}]};
				_E ->
					?AERR("Unable to copy actor ~p to ~p",[CopyFrom,Name]),
					{ok,[{columns,{<<"status">>}},{row,{<<"failed">>}}]}
			end;
		Pid ->
			diepls(Pid,overwrite),
			Ref = erlang:monitor(process,Pid),
			receive
				{'DOWN',Ref,_,_Pid,_} ->
					read(Name,Flags,[{copy,CopyFrom}],Start)
				after 2000 ->
					{ok,[{columns,{<<"status">>}},{row,{<<"failed_running">>}}]}
			end
	end;
read(Name,Flags,[delete],Start) ->
	% transaction = {0,0,<<>>}
	call(Name,Flags,#write{sql = delete, flags = Flags},Start);
read(Name,Flags,{Sql,[]},Start) ->
	call(Name,Flags,#read{sql = Sql, flags = Flags},Start);
read(Name,Flags,Sql,Start) ->
	call(Name,Flags,#read{sql = Sql, flags = Flags},Start).

write(Name,Flags,{{_,_,_} = TransactionId,Sql},Start) ->
	write(Name,Flags,{undefined,TransactionId,Sql},Start);
write(Name,Flags,{MFA,TransactionId,Sql},Start) ->
	case TransactionId of
		{_,_,_} ->
			case Sql of
				commit ->
					call(Name,Flags,{commit,true,TransactionId},Start);
				abort ->
					call(Name,Flags,{commit,false,TransactionId},Start);
				[delete] ->
					W = #write{mfa = MFA,sql = delete, transaction = TransactionId, flags = Flags},
					call(Name,Flags,W,Start);
				{Sql0, PreparedStatements} ->
					W = #write{mfa = MFA,sql = iolist_to_binary(Sql0), records = PreparedStatements,
						transaction = TransactionId, flags = Flags},
					call(Name,Flags,W,Start);
				_ ->
					W = #write{mfa = MFA,sql = iolist_to_binary(Sql),
						transaction = TransactionId, flags = Flags},
					call(Name,Flags,W,Start)
			end;
		_ when Sql == undefined ->
			call(Name,Flags,#write{mfa = MFA, flags = Flags},Start);
		_ ->
			W = #write{mfa = MFA, sql = iolist_to_binary(Sql), flags = Flags},
			call(Name,[wait_election|Flags],W,Start)
	end;
write(Name,Flags,[delete],Start) ->
	call(Name,Flags,#write{sql = delete, flags = Flags},Start);
write(Name,Flags,{Sql,Records},Start) ->
	W = #write{sql = iolist_to_binary(Sql), records = Records, flags = Flags},
	call(Name,[wait_election|Flags],W,Start);
write(Name,Flags,Sql,Start) ->
	W = #write{sql = iolist_to_binary(Sql), flags = Flags},
	call(Name,[wait_election|Flags],W,Start).


call(Name,Flags,Msg,Start) ->
	call(Name,Flags,Msg,Start,false).
call(Name,Flags,Msg,Start,IsRedirect) ->
	case distreg:whereis(Name) of
		undefined ->
			case startactor(Name,Start,[{startreason,Msg}|Flags]) of %
				{ok,Pid} when is_pid(Pid) ->
					call(Name,Flags,Msg,Start,IsRedirect,Pid);
				{error,nocreate} ->
					{error,nocreate};
				Res ->
					Res
			end;
		Pid ->
			% ?INF("Call have pid ~p for name ~p, alive ~p",[Pid,Name,erlang:is_process_alive(Pid)]),
			call(Name,Flags,Msg,Start,IsRedirect,Pid)

	end.
call(Name,Flags,Msg,Start,IsRedirect,Pid) ->
	% If call returns redirect, this is slave node not master node.
	% test_mon_calls(Name,Msg),
	case catch gen_server:call(Pid,Msg,infinity) of
		{redirect,Node} when is_binary(Node) ->
			% test_mon_stop(),
			?ADBG("Redirect call ~p",[Node]),
			case lists:member(Node,bkdcore:cluster_nodes()) of
				true ->
					case IsRedirect of
						true ->
							double_redirect;
						_ ->
							case actordb:rpc(Node,element(1,Name),{?MODULE,call,[Name,Flags,Msg,Start,true]}) of
								double_redirect ->
									diepls(Pid,nomaster),
									call(Name,Flags,Msg,Start);
								Res ->
									Res
							end
					end;
				false ->
					case IsRedirect of
						onlylocal ->
							{redirect,Node};
						_ ->
							case actordb:rpc(Node,element(1,Name),{?MODULE,call,[Name,Flags,Msg,Start,false]}) of
								{error,Connerr} when Connerr == econnrefused; Connerr == timeout ->
									Pid ! doelection,
									call(Name,Flags,Msg,Start,false,Pid);
								Res ->
									Res
							end
					end
			end;
		{'EXIT',{noproc,_}} = _X  ->
			?ADBG("noproc call again ~p",[_X]),
			call(Name,Flags,Msg,Start);
		{'EXIT',{normal,_}} ->
			?ADBG("died normal"),
			call(Name,Flags,Msg,Start);
		{'EXIT',{nocreate,_}} ->
			% test_mon_stop(),
			{error,nocreate};
		{'EXIT',{error,_} = E} ->
			E;
		Res ->
			% test_mon_stop(),
			Res
	end.

startactor(Name,Start,Flags) ->
	case Start of
		{Mod,Func,Args} ->
			apply(Mod,Func,[Name|Args]);
		undefined ->
			{ok,undefined};
		_ ->
			apply(Start,start,[Name,Flags])
	end.

% test_mon_calls(Who,Msg) ->
% 	Ref = make_ref(),
% 	put(ref,Ref),
% 	put(refpid,spawn(fun() -> test_mon_proc(Who,Msg,Ref) end)).
% test_mon_proc(Who,Msg,Ref) ->
% 	receive
% 		Ref ->
% 			ok
% 		after 1000 ->
% 			?AERR("Still waiting on ~p, for ~p",[Who,Msg]),
% 			test_mon_proc(Who,Msg,Ref)
% 	end.
% test_mon_stop() ->
% 	butil:safesend(get(refpid), get(ref)).


call_slave(Cb,Actor,Type,Msg) ->
	call_slave(Cb,Actor,Type,Msg,[]).
call_slave(Cb,Actor,Type,Msg,Flags) ->
	actordb_util:wait_for_startup(Type,Actor,0),
	case apply(Cb,cb_slave_pid,[Actor,Type,[{startreason,Msg}|Flags]]) of
		{ok,Pid} ->
			ok;
		Pid when is_pid(Pid) ->
			ok
	end,
	case catch gen_server:call(Pid,Msg,infinity) of
		{'EXIT',{noproc,_}} ->
			call_slave(Cb,Actor,Type,Msg);
		{'EXIT',{normal,_}} ->
			call_slave(Cb,Actor,Type,Msg);
		Res ->
			Res
	end.

diepls(Pid,Reason) ->
	gen_server:cast(Pid,{diepls,Reason}).

start_copylock(Fullname,O) ->
	start_copylock(Fullname,O,0).
start_copylock(Fullname,Opt,N) when N < 2 ->
	case distreg:whereis(Fullname) of
		undefined ->
			start(Opt);
		_ ->
			timer:sleep(1000),
			start_copylock(Fullname,Opt,N+1)
	end;
start_copylock(Fullname,_,_) ->
	Pid = distreg:whereis(Fullname),
	print_info(Pid),
	{error,{slave_proc_running,Pid,Fullname}}.

% Opts:
% [{actor,Name},{type,Type},{mod,CallbackModule},{state,CallbackState},
%  {inactivity_timeout,SecondsOrInfinity},{slave,true/false},{copyfrom,NodeName},{copyreset,{Mod,Func,Args}}]
start(Opts) ->
	?ADBG("Starting ~p slave=~p",[butil:ds_vals([actor,type],Opts),butil:ds_val(slave,Opts)]),
	Ref = make_ref(),
	case gen_server:start(?MODULE, [{start_from,{self(),Ref}}|Opts], []) of
		{ok,Pid} ->
			{ok,Pid};
		{error,normal} ->
			% Init failed gracefully. It should have sent an explanation.
			receive
				{Ref,nocreate} ->
					{error,nocreate};
				{Ref,{registered,Pid}} ->
					{ok,Pid};
				{Ref,{actornum,Path,Num}} ->
					{ok,Path,Num};
				{Ref,{ok,[{columns,_},_]} = Res} ->
					Res;
				{Ref,nostart} ->
					{error,nostart}
				after 0 ->
					{error,cantstart}
			end;
		Err ->
			?AERR("start sqlproc error ~p",[Err]),
			Err
	end.

stop(Pid) when is_pid(Pid) ->
	Pid ! stop;
stop(Name) ->
	case distreg:whereis(Name) of
		undefined ->
			ok;
		Pid ->
			stop(Pid)
	end.

print_info(Pid) ->
	gen_server:cast(Pid,print_info).

% Call processing.
% Calls are processed here and in actordb_sqlprocutil:doqueue.
% Only in handle_call are we allowed to add calls to callqueue.
handle_call(Msg,_,P) when is_binary(P#dp.movedtonode) ->
	?DBG("REDIRECT BECAUSE MOVED TO NODE ~p ~p",[P#dp.movedtonode,Msg]),
	case apply(P#dp.cbmod,cb_redirected_call,[P#dp.cbstate,P#dp.movedtonode,Msg,moved]) of
		{reply,What,NS,Red} ->
			{reply,What,P#dp{cbstate = NS, movedtonode = Red}};
		ok ->
			{reply,{redirect,P#dp.movedtonode},P#dp{activity = make_ref()}}
	end;
handle_call({dbcopy,Msg},CallFrom,P) ->
	Me = actordb_conf:node_name(),
	case ok of
		_ when element(1,Msg) == send_db andalso P#dp.verified == false ->
			{noreply,P#dp{callqueue = queue:in_r({CallFrom,{dbcopy,Msg}},P#dp.callqueue)}};
		_ when element(1,Msg) == send_db andalso Me /= P#dp.masternode ->
			?DBG("redirect not master node"),
			actordb_sqlprocutil:redirect_master(P);
		_ ->
			actordb_sqlprocutil:dbcopy_call(Msg,CallFrom,P)
	end;
handle_call({state_rw,_} = Msg,From, #dp{wasync = #ai{wait = WRef}} = P) when is_reference(WRef) ->
	?DBG("Queuing state call"),
	{noreply,P#dp{statequeue = queue:in_r({From,Msg},P#dp.statequeue)}};
handle_call({state_rw,What},From,P) ->
	state_rw_call(What,From,P#dp{activity = make_ref()});
handle_call({commit,Doit,Id},From, P) ->
	commit_call(Doit,Id,From,P);
handle_call(Msg,From,P) ->
	case Msg of
		_ when P#dp.mors == slave ->
			case P#dp.masternode of
				undefined ->
					?DBG("Queing msg no master yet ~p",[Msg]),
					{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue),
									election = actordb_sqlprocutil:election_timer(P#dp.election),
									flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION)}};
				_ ->
					case apply(P#dp.cbmod,cb_redirected_call,[P#dp.cbstate,P#dp.masternode,Msg,slave]) of
						{reply,What,NS,_} ->
							{reply,What,P#dp{cbstate = NS}};
						ok ->
							actordb_sqlprocutil:redirect_master(P)
					end
			end;
		_ when P#dp.verified == false ->
			case is_pid(P#dp.election) andalso P#dp.flags band ?FLAG_WAIT_ELECTION > 0 of
				true ->
					P#dp.election ! exit,
					handle_call(Msg,From,P#dp{flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION)});
				_ ->
					case apply(P#dp.cbmod,cb_unverified_call,[P#dp.cbstate,Msg]) of
						queue ->
							{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue)}};
						{moved,Moved} ->
							{noreply,P#dp{movedtonode = Moved}};
						{moved,Moved,NS} ->
							{noreply,P#dp{movedtonode = Moved, cbstate = NS}};
						{reply,What} ->
							{reply,What,P};
						{reinit_master,Mors} ->
							{ok,NP} = init(P#dp{mors = Mors},cb_reinit),
							{noreply,NP};
						{reinit,Sql,NS} ->
							{ok,NP} = init(P#dp{cbstate = NS,
								callqueue = queue:in_r({From,#write{sql = Sql}},P#dp.callqueue)},cb_reinit),
							{noreply,NP}
					end
			end;
		% Same transaction can write to an actor more than once
		% Transactions do not use async calls to driver, so if we are in the middle of one, we can execute
		% this write immediately.
		#write{transaction = TransactionId} = Msg1 when
				P#dp.transactionid == TransactionId,P#dp.transactionid /= undefined ->
			write_call1(Msg1,From,P#dp.schemavers,P);
		#read{} when P#dp.movedtonode == undefined ->
			% read call just buffers call
			read_call(Msg,From,P);
		#write{transaction = undefined} when P#dp.movedtonode == undefined ->
			% write_call just buffers call, we can always run it.
			% Actual write is executed at the end of doqueue.
			write_call(Msg,From,P);
		_ when P#dp.movedtonode == deleted andalso (element(1,Msg) == read orelse element(1,Msg) == write) ->
			% #write and #read have flags in same pos
			Flags = element(#write.flags,Msg),
			case lists:member(create,Flags) of
				true ->
					% WC = actordb_sqlprocutil:actually_delete(P),
					% write_call(WC, undefined,
					% 	P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue),
					% 		activity = make_ref(), movedtonode = undefined});
					{stop,normal,P};
				false ->
					{reply, {error,nocreate},P}
			end;
		_ ->
			?DBG("Queing msg ~p, callres ~p, locked ~p, transactionid ~p",
				[Msg,P#dp.callres,P#dp.locked,P#dp.transactionid]),
			% Continue in doqueue
			{noreply,P#dp{callqueue = queue:in_r({From,Msg},P#dp.callqueue)},0}
	end.


commit_call(Doit,Id,From,P) ->
	?DBG("Commit doit=~p, id=~p, from=~p, trans=~p",[Doit,Id,From,P#dp.transactionid]),
	case P#dp.transactionid == Id of
		true ->
			case P#dp.transactioncheckref of
				undefined ->
					ok;
				_ ->
					erlang:demonitor(P#dp.transactioncheckref)
			end,
			?DBG("Commit write ~p",[P#dp.transactioninfo]),
			{Sql,EvNum,_NewVers} = P#dp.transactioninfo,
			case Sql of
				<<"delete">> when Doit == true ->
					Moved = deleted;
				_ ->
					Moved = P#dp.movedtonode
			end,
			case Doit of
				% true when Sql == <<"delete">> ->
				% 	% ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"#s01;">>)),
				% 	reply(From,ok),
				% 	?DBG("Commit delete"),
				% 	% actordb_sqlprocutil:delete_actor(P),
				% 	{noreply,ae_timer(P#dp{})};
				true when P#dp.follower_indexes == [] ->
					case Moved of
						deleted ->
							Me = self(),
							actordb_sqlprocutil:delete_actor(P),
							spawn(fun() -> ?DBG("Stopping in commit"), stop(Me) end);
						_ ->
							ok = actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"#s01;">>))
					end,
					{reply,ok,actordb_sqlprocutil:doqueue(P#dp{transactionid = undefined,
						transactioncheckref = undefined,
						transactioninfo = undefined, activity = make_ref(),movedtonode = Moved,
						evnum = EvNum, evterm = P#dp.current_term})};
				true ->
					% We can safely release savepoint.
					% This will send the remaining WAL pages to followers that have commit flag set.
					% Followers will then rpc back appendentries_response.
					% We can also set #dp.evnum now.
					VarHeader = actordb_sqlprocutil:create_var_header(P),
					actordb_sqlite:okornot(actordb_sqlite:exec(P#dp.db,<<"#s01;">>,
												P#dp.evterm,EvNum,VarHeader)),
					{noreply,ae_timer(P#dp{callfrom = From, activity = make_ref(),
						callres = ok,evnum = EvNum,movedtonode = Moved,
						follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
						transactionid = undefined, transactioninfo = undefined,
						transactioncheckref = undefined})};
				false when P#dp.follower_indexes == [] ->
					% case Sql of
					% 	<<"delete">> ->
					% 		ok;
					% 	_ ->
							actordb_sqlite:rollback(P#dp.db),
					% end,
					{reply,ok,actordb_sqlprocutil:doqueue(P#dp{transactionid = undefined,
					transactioninfo = undefined,transactioncheckref = undefined,activity = make_ref()})};
				false ->
					% Transaction failed.
					% Delete it from __transactions.
					% EvNum will actually be the same as transactionsql that we have not finished.
					%  Thus this EvNum section of WAL contains pages from failed transaction and
					%  cleanup of transaction from __transactions.
					{Tid,Updaterid,_} = P#dp.transactionid,
					% case Sql of
					% 	<<"delete">> ->
					% 		ok;
					% 	_ ->
							% actordb_sqlite:exec(P#dp.db,<<"ROLLBACK;">>,P#dp.evterm,P#dp.evnum,<<>>)
							ok = actordb_sqlite:rollback(P#dp.db),
					% end,
					NewSql = <<"DELETE FROM __transactions WHERE tid=",(butil:tobin(Tid))/binary," AND updater=",
									(butil:tobin(Updaterid))/binary,";">>,
					write_call(#write{sql = NewSql},From,P#dp{callfrom = undefined,
										transactionid = undefined,transactioninfo = undefined,
										transactioncheckref = undefined})
			end;
		_ ->
			{reply,ok,P}
	end.

state_rw_call(donothing,_From,P) ->
	{reply,ok,P};
state_rw_call(recovered,_From,P) ->
	{reply,ok,P#dp{inrecovery = false}};
state_rw_call({appendentries_start,Term,LeaderNode,PrevEvnum,PrevTerm,AEType,CallCount} = What,From,P) ->
	% Executed on follower.
	% AE is split into multiple calls (because wal is sent page by page as it is written)
	% Start sets parameters. There may not be any wal append calls after if empty write.
	% AEType = [head,empty,recover]
	?DBG("AE start ~p {PrevEvnum,PrevTerm}=~p leader=~p",[AEType, {PrevEvnum,PrevTerm},LeaderNode]),
	case ok of
		_ when P#dp.inrecovery, AEType == head ->
			?DBG("Ignoring head because inrecovery"),
			Now = os:timestamp(),
			Diff = timer:now_diff(Now,P#dp.recovery_age),
			% Reply may have gotten lost or leader could have changed.
			case Diff > 2000000 of
				true ->
					?ERR("Recovery mode timeout ~p",[Diff]),
					state_rw_call(What,From,P#dp{inrecovery = false});
				false ->
					{reply,false,P}
			end;
		_ when is_pid(P#dp.copyproc) ->
			?DBG("Ignoring AE because copy in progress"),
			{reply,false,P};
		_ when Term < P#dp.current_term ->
			?ERR("AE start, input term too old ~p {InTerm,MyTerm}=~p",
					[AEType,{Term,P#dp.current_term}]),
			reply(From,false),
			actordb_sqlprocutil:ae_respond(P,LeaderNode,false,PrevEvnum,AEType,CallCount),
			% Some node thinks its master and sent us appendentries start.
			% Because we are master with higher term, we turn it down.
			% But we also start a new election so that nodes get synchronized.
			case P#dp.mors of
				master ->
					{noreply, actordb_sqlprocutil:start_verify(P,false)};
				_ ->
					{noreply,P}
			end;
		_ when P#dp.mors == slave, P#dp.masternode /= LeaderNode ->
			?DBG("AE start, slave now knows leader ~p ~p",[AEType,LeaderNode]),
			case P#dp.callres /= undefined of
				true ->
					reply(P#dp.callfrom,{redirect,LeaderNode});
				false ->
					ok
			end,
			actordb_local:actor_mors(slave,LeaderNode),
			NP = P#dp{masternode = LeaderNode,without_master_since = undefined,
			masternodedist = bkdcore:dist_name(LeaderNode),
			callfrom = undefined, callres = undefined,verified = true},
			state_rw_call(What,From,actordb_sqlprocutil:doqueue(actordb_sqlprocutil:reopen_db(NP)));
		% This node is candidate or leader but someone with newer term is sending us log
		_ when P#dp.mors == master ->
			?ERR("AE start, stepping down as leader ~p ~p",
					[AEType,{Term,P#dp.current_term}]),
			case P#dp.callres /= undefined of
				true ->
					reply(P#dp.callfrom,{redirect,LeaderNode});
				false ->
					ok
			end,
			actordb_local:actor_mors(slave,LeaderNode),
			NP = P#dp{mors = slave, verified = true, election = undefined,
				voted_for = undefined,callfrom = undefined, callres = undefined,
				masternode = LeaderNode,without_master_since = undefined,
				masternodedist = bkdcore:dist_name(LeaderNode),
				current_term = Term},
			state_rw_call(What,From,actordb_sqlprocutil:doqueue(
				actordb_sqlprocutil:save_term(actordb_sqlprocutil:reopen_db(NP))));
		_ when P#dp.evnum /= PrevEvnum; P#dp.evterm /= PrevTerm ->
			?ERR("AE start failed, evnum evterm do not match, type=~p, {MyEvnum,MyTerm}=~p, {InNum,InTerm}=~p",
						[AEType,{P#dp.evnum,P#dp.evterm},{PrevEvnum,PrevTerm}]),
			case ok of
				% Node is conflicted, delete last entry
				_ when PrevEvnum > 0, AEType == recover, P#dp.evnum > 0 ->
					NP = actordb_sqlprocutil:rewind_wal(P);
				% If false this node is behind. If empty this is just check call.
				% Wait for leader to send an earlier event.
				_ ->
					NP = P
			end,
			reply(From,false),
			actordb_sqlprocutil:ae_respond(NP,LeaderNode,false,PrevEvnum,AEType,CallCount),
			{noreply,NP};
		_ when Term > P#dp.current_term ->
			?ERR("AE start, my term out of date type=~p {InTerm,MyTerm}=~p",
				[AEType,{Term,P#dp.current_term}]),
			NP = P#dp{current_term = Term,voted_for = undefined,
			masternode = LeaderNode, without_master_since = undefined,verified = true,
			masternodedist = bkdcore:dist_name(LeaderNode)},
			state_rw_call(What,From,actordb_sqlprocutil:doqueue(actordb_sqlprocutil:save_term(NP)));
		_ when AEType == empty ->
			?DBG("AE start, ok for empty"),
			reply(From,ok),
			actordb_sqlprocutil:ae_respond(P,LeaderNode,true,PrevEvnum,AEType,CallCount),
			{noreply,P#dp{verified = true}};
		% Ok, now it will start receiving wal pages
		_ ->
			case AEType == recover of
				true ->
					Age = os:timestamp(),
					?INF("AE start ok for recovery from ~p, evnum=~p, evterm=~p",
						[LeaderNode,P#dp.evnum,P#dp.evterm]);
				false ->
					Age = P#dp.recovery_age,
					?DBG("AE start ok from ~p",[LeaderNode])
			end,
			{reply,ok,P#dp{verified = true, inrecovery = AEType == recover, recovery_age = Age}}
	end;
% Executed on follower.
% sqlite wal, header tells you if done (it has db size in header)
state_rw_call({appendentries_wal,Term,Header,Body,AEType,CallCount},From,P) ->
	case ok of
		_ when Term == P#dp.current_term; AEType == head ->
			append_wal(P,From,CallCount,Header,Body,AEType);
		_ ->
			?ERR("AE WAL received wrong term ~p",[{Term,P#dp.current_term}]),
			reply(From,false),
			actordb_sqlprocutil:ae_respond(P,P#dp.masternode,false,P#dp.evnum,AEType,CallCount),
			{noreply,P}
	end;
% Executed on leader.
state_rw_call({appendentries_response,Node,CurrentTerm,Success,
			EvNum,EvTerm,MatchEvnum,AEType,{SentIndex,SentTerm}} = What,From,P) ->
	Follower = lists:keyfind(Node,#flw.node,P#dp.follower_indexes),
	case Follower of
		false ->
			?DBG("Adding node to follower list ~p",[Node]),
			state_rw_call(What,From,actordb_sqlprocutil:store_follower(P,#flw{node = Node}));
		_ when (not (AEType == head andalso Success)) andalso
				(SentIndex /= Follower#flw.match_index orelse
				SentTerm /= Follower#flw.match_term orelse P#dp.verified == false) ->
			% We can get responses from AE calls which are out of date. This is why the other node always sends
			%  back {SentIndex,SentTerm} which are the parameters for follower that we knew of when we sent data.
			% If these two parameters match our current state, then response is valid.
			?DBG("ignoring AE resp, from=~p,success=~p,type=~p,prevevnum=~p,evnum=~p,matchev=~p, sent=~p",
				[Node,Success,AEType,Follower#flw.match_index,EvNum,MatchEvnum,{SentIndex,SentTerm}]),
			{reply,ok,P};
		_ ->
			?DBG("AE resp,from=~p,success=~p,type=~p,prevnum=~p,prevterm=~p evnum=~p,evterm=~p,matchev=~p",
				[Node,Success,AEType,Follower#flw.match_index,Follower#flw.match_term,EvNum,EvTerm,MatchEvnum]),
			NFlw = Follower#flw{match_index = EvNum, match_term = EvTerm,next_index = EvNum+1,
									wait_for_response_since = undefined, last_seen = os:timestamp()},
			case Success of
				% An earlier response.
				_ when P#dp.mors == slave ->
					?ERR("Received AE response after stepping down"),
					{reply,ok,P};
				true ->
					reply(From,ok),
					NP = actordb_sqlprocutil:reply_maybe(actordb_sqlprocutil:continue_maybe(
						P,NFlw,AEType == head orelse AEType == empty)),
					?DBG("AE response for node ~p, followers=~p",
							[Node,[{F#flw.node,F#flw.match_index,F#flw.next_index} || F <- NP#dp.follower_indexes]]),
					{noreply,NP};
				% What we thought was follower is ahead of us and we need to step down
				false when P#dp.current_term < CurrentTerm ->
					?DBG("My term is out of date {His,Mine}=~p",[{CurrentTerm,P#dp.current_term}]),
					{reply,ok,actordb_sqlprocutil:reopen_db(actordb_sqlprocutil:save_term(
						P#dp{mors = slave,current_term = CurrentTerm,
							election = actordb_sqlprocutil:election_timer(P#dp.election),
							masternode = undefined, without_master_since = os:timestamp(),
							masternodedist = undefined,
							voted_for = undefined, follower_indexes = []}))};
				false when NFlw#flw.match_index == P#dp.evnum ->
					% Follower is up to date. He replied false. Maybe our term was too old.
					{reply,ok,actordb_sqlprocutil:reply_maybe(actordb_sqlprocutil:store_follower(P,NFlw))};
				false ->
					% If we are copying entire db to that node already, do nothing.
					case [C || C <- P#dp.dbcopy_to, C#cpto.node == Node, C#cpto.actorname == P#dp.actorname] of
						[_|_] ->
							?DBG("Ignoring appendendentries false response because copying to"),
							{reply,ok,P};
						[] ->
							case actordb_sqlprocutil:try_wal_recover(P,NFlw) of
								{false,NP,NF} ->
									?DBG("Can not recover from log, sending entire db"),
									% We can not recover from wal. Send entire db.
									Ref = make_ref(),
									case bkdcore:rpc(NF#flw.node,{?MODULE,call_slave,
											[P#dp.cbmod,P#dp.actorname,P#dp.actortype,
											{dbcopy,{start_receive,actordb_conf:node_name(),Ref}}]}) of
										ok ->
											DC = {send_db,{NF#flw.node,Ref,false,P#dp.actorname}},
											actordb_sqlprocutil:dbcopy_call(DC,From,NP);
										_Err ->
											?ERR("Unable to send db ~p",[_Err]),
											{reply,false,P}
									end;
								{true,NP,NF} ->
									% we can recover from wal
									?DBG("Recovering from wal, for node=~p, match_index=~p, match_term=~p, myevnum=~p",
											[NF#flw.node,NF#flw.match_index,NF#flw.match_term,P#dp.evnum]),
									reply(From,ok),
									{noreply,actordb_sqlprocutil:continue_maybe(NP,NF,false)}
							end
					end
			end
	end;
state_rw_call({request_vote,Candidate,NewTerm,LastEvnum,LastTerm} = What,From,P) ->
	?DBG("Request vote for=~p, mors=~p, {histerm,myterm}=~p, {HisLogTerm,MyLogTerm}=~p {HisEvnum,MyEvnum}=~p",
	[Candidate,P#dp.mors,{NewTerm,P#dp.current_term},{LastTerm,P#dp.evterm},{LastEvnum,P#dp.evnum}]),
	Uptodate =
		case ok of
			_ when P#dp.evterm < LastTerm ->
				true;
			_ when P#dp.evterm > LastTerm ->
				false;
			_ when P#dp.evnum < LastEvnum ->
				true;
			_ when P#dp.evnum > LastEvnum ->
				false;
			_ ->
				true
		end,
	Follower = lists:keyfind(Candidate,#flw.node,P#dp.follower_indexes),
	case Follower of
		false when P#dp.mors == master ->
			?DBG("Adding node to follower list ~p",[Candidate]),
			state_rw_call(What,From,actordb_sqlprocutil:store_follower(P,#flw{node = Candidate}));
		_ ->
			case ok of
				% Candidates term is lower than current_term, ignore.
				_ when NewTerm < P#dp.current_term ->
					DoElection = (P#dp.mors == master andalso P#dp.verified == true),
					reply(From,{outofdate,actordb_conf:node_name(),P#dp.current_term,{P#dp.evnum,P#dp.evterm}}),
					NP = P;
				% We've already seen this term, only vote yes if we have not voted
				%  or have voted for this candidate already.
				_ when NewTerm == P#dp.current_term ->
					case (P#dp.voted_for == undefined orelse P#dp.voted_for == Candidate) of
						true when Uptodate ->
							DoElection = false,
							reply(From,{true,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
							NP = actordb_sqlprocutil:save_term(P#dp{voted_for = Candidate,
							current_term = NewTerm,
							election = actordb_sqlprocutil:election_timer(P#dp.election),
							masternode = undefined, without_master_since = os:timestamp(),
							masternodedist = undefined});
						true ->
							DoElection = (P#dp.mors == master andalso P#dp.verified == true),
							reply(From,{outofdate,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
							NP = actordb_sqlprocutil:save_term(P#dp{voted_for = undefined, current_term = NewTerm});
						false ->
							DoElection =(P#dp.mors == master andalso P#dp.verified == true),
							AV = {alreadyvoted,actordb_conf:node_name(),P#dp.current_term,{P#dp.evnum,P#dp.evterm}},
							reply(From,AV),
							NP = P
					end;
				% New candidates term is higher than ours, is he as up to date?
				_ when Uptodate ->
					DoElection = false,
					reply(From,{true,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
					NP = actordb_sqlprocutil:save_term(P#dp{voted_for = Candidate, current_term = NewTerm,
					election = actordb_sqlprocutil:election_timer(P#dp.election),
					masternode = undefined, without_master_since = os:timestamp(),
					masternodedist = undefined});
				% Higher term, but not as up to date. We can not vote for him.
				% We do have to remember new term index though.
				_ ->
					DoElection = (P#dp.mors == master andalso P#dp.verified == true),
					reply(From,{outofdate,actordb_conf:node_name(),NewTerm,{P#dp.evnum,P#dp.evterm}}),
					NP = actordb_sqlprocutil:save_term(P#dp{voted_for = undefined, current_term = NewTerm,
						election = actordb_sqlprocutil:election_timer(P#dp.election)})
			end,
			% If voted no and we are leader, start a new term,
			% which causes a new write and gets all nodes synchronized.
			% If the other node is actually more up to date, vote was yes and we do not do election.
			?DBG("Doing election after request_vote? ~p, mors=~p, verified=~p, election=~p",
					[DoElection,P#dp.mors,P#dp.verified,P#dp.election]),
			{noreply,NP#dp{election = actordb_sqlprocutil:election_timer(P#dp.election)}}
	end;
state_rw_call({delete,_MovedToNode},From,P) ->
	ok = actordb_driver:wal_rewind(P#dp.db,0),
	reply(From,ok),
	{stop,normal,P};
state_rw_call(checkpoint,_From,P) ->
	actordb_sqlprocutil:checkpoint(P),
	{reply,ok,P}.

append_wal(P,From,CallCount,[Header|HT],[Body|BT],AEType) ->
	case append_wal(P,From,CallCount,Header,Body,AEType) of
		{noreply,NP} ->
			{noreply,NP};
		{reply,ok,NP} when HT /= [] ->
			append_wal(NP,From,CallCount,HT,BT,AEType);
		{reply,ok,NP} ->
			{reply,ok,NP}
	end;
append_wal(P,From,CallCount,Header,Body,AEType) ->
	AWR = actordb_sqlprocutil:append_wal(P,Header,Body),
	case AWR of
		ok ->
			case Header of
				% dbsize == 0, not last page
				<<_:20/binary,0:32>> ->
					?DBG("AE append ~p",[AEType]),
					{reply,ok,P#dp{locked = [ae]}};
				% last page
				<<Evterm:64/unsigned-big,Evnum:64/unsigned-big,Pgno:32,Commit:32>> ->
					?DBG("AE WAL done evnum=~p,evterm=~p,aetype=~p,qempty=~p,master=~p,pgno=~p,commit=~p",
							[Evnum,Evterm,AEType,queue:is_empty(P#dp.callqueue),P#dp.masternode,Pgno,Commit]),
					% Prevent any timeouts on next ae since recovery process is progressing.
					case P#dp.inrecovery of
						true ->
							RecoveryAge = os:timestamp();
						false ->
							RecoveryAge = P#dp.recovery_age
					end,
					NP = P#dp{evnum = Evnum, evterm = Evterm,locked = [], recovery_age = RecoveryAge},
					reply(From,done),
					actordb_sqlprocutil:ae_respond(NP,NP#dp.masternode,true,P#dp.evnum,AEType,CallCount),
					{noreply,NP}
			end;
		_ ->
			reply(From,false),
			actordb_sqlprocutil:ae_respond(P,P#dp.masternode,false,P#dp.evnum,AEType,CallCount),
			{noreply,P}
	end.

read_call(#read{sql = [exists]},_From,#dp{mors = master} = P) ->
	{reply,{ok,[{columns,{<<"exists">>}},{rows,[{<<"true">>}]}]},P};
read_call(Msg,From,#dp{mors = master, rasync = AR} = P) ->
	case Msg#read.sql of
		{Mod,Func,Args} ->
			case apply(Mod,Func,[P#dp.cbstate|Args]) of
				{reply,What,Sql,NS} ->
					% {reply,{What,actordb_sqlite:exec(P#dp.db,Sql,read)},P#dp{cbstate = NS}};
					AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [{tuple,What,From}|AR#ai.buffer_cf],
					buffer_recs = [[]|AR#ai.buffer_recs]},
					{noreply,P#dp{cbstate = NS, rasync = AR1}, 0};
				{reply,What,NS} ->
					{reply,What,P#dp{cbstate = NS}, 0};
				{reply,What} ->
					{reply,What,P, 0};
				{Sql,State} ->
					AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [From|AR#ai.buffer_cf],
						buffer_recs = [[]|AR#ai.buffer_recs]},
					{noreply,P#dp{cbstate = State, rasync = AR1}, 0};
				Sql ->
					AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [From|AR#ai.buffer_cf],
						buffer_recs = [[]|AR#ai.buffer_recs]},
					% {reply,actordb_sqlite:exec(P#dp.db,Sql,read),P}
					{noreply,P#dp{rasync = AR1}, 0}
			end;
		{Sql,{Mod,Func,Args}} ->
			AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [{mod,{Mod,Func,Args},From}|AR#ai.buffer_cf],
				buffer_recs = [[]|AR#ai.buffer_recs]},
			{noreply,P#dp{rasync = AR1}, 0};
		{Sql,Recs} ->
			% {reply,actordb_sqlite:exec(P#dp.db,Sql,Recs,read),P};
			AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [From|AR#ai.buffer_cf],
				buffer_recs = [Recs|AR#ai.buffer_recs]},
			{noreply,P#dp{rasync = AR1}, 0};
		Sql ->
			% {reply,actordb_sqlite:exec(P#dp.db,Sql,read),P}
			AR1 = AR#ai{buffer = [Sql|AR#ai.buffer], buffer_cf = [From|AR#ai.buffer_cf],
				buffer_recs = [[]|AR#ai.buffer_recs]},
			{noreply,P#dp{rasync = AR1}, 0}
	end;
read_call(_Msg,_From,P) ->
	?DBG("redirect read ~p",[P#dp.masternode]),
	actordb_sqlprocutil:redirect_master(P).

% Execute buffered read sqls
read_call1(Sql,Recs,From,P) ->
	ComplSql = list_to_tuple(Sql),
	Records = list_to_tuple(Recs),
	?DBG("READ SQL=~p, Recs=~p, from=~p",[ComplSql, Records,From]),
	Res = actordb_sqlite:exec_async(P#dp.db,ComplSql,Records,read),
	A = P#dp.rasync,
	NRB = A#ai{wait = Res, info = Sql, callfrom = From, buffer = [], buffer_cf = [], buffer_recs = []},
	P#dp{rasync = NRB}.

write_call(#write{mfa = MFA, sql = Sql} = Msg,From,P) ->
	?DBG("writecall evnum_prewrite=~p,term=~p, writeinfo=~p",
		[P#dp.evnum,P#dp.current_term,{MFA,Sql}]),
	A = P#dp.wasync,
	case Sql of
		delete ->
			A1 = A#ai{buffer = [<<"#s02;">>|A#ai.buffer], buffer_cf = [From|A#ai.buffer_cf],
				buffer_recs = [[[[?MOVEDTOI,<<"$deleted$">>]]]|A#ai.buffer_recs], buffer_moved = deleted},
			{noreply,P#dp{wasync = A1},0};
		{moved,MovedTo} ->
			A1 = A#ai{buffer = [<<"#s02;">>|A#ai.buffer], buffer_cf = [From|A#ai.buffer_cf],
				buffer_recs = [[[[?MOVEDTOI,MovedTo]]]|A#ai.buffer_recs], buffer_moved = {moved,MovedTo}},
			{noreply,P#dp{wasync = A1},0};
		_ when MFA == undefined ->
			A1 = A#ai{buffer = [Sql|A#ai.buffer], buffer_cf = [From|A#ai.buffer_cf],
				buffer_recs = [Msg#write.records|A#ai.buffer_recs]},
			{noreply,P#dp{wasync = A1},0};
		_ ->
			{Mod,Func,Args} = MFA,
			case apply(Mod,Func,[P#dp.cbstate|Args]) of
				{reply,What,OutSql,NS} ->
					reply(From,What),
					A1 = A#ai{buffer = [OutSql|A#ai.buffer], buffer_recs = [[]|A#ai.buffer_recs], buffer_cf = [undefined|A#ai.buffer_cf]},
					{noreply,P#dp{wasync = A1, cbstate = NS}, 0};
				{reply,What,NS} ->
					{reply,What,P#dp{cbstate = NS},0};
				{reply,What} ->
					{reply,What,P,0};
				{exec,OutSql,Recs} ->
					A1 = A#ai{buffer = [OutSql|A#ai.buffer], buffer_recs = [Recs|A#ai.buffer_recs], buffer_cf = [From|A#ai.buffer_cf]},
					{noreply,P#dp{wasync = A1},0};
				{OutSql,State} ->
					A1 = A#ai{buffer = [OutSql|A#ai.buffer], buffer_recs = [[]|A#ai.buffer_recs], buffer_cf = [From|A#ai.buffer_cf]},
					{noreply,P#dp{wasync = A1, cbstate = State},0};
				{OutSql,Recs,State} ->
					A1 = A#ai{buffer = [OutSql|A#ai.buffer], buffer_recs = [Recs|A#ai.buffer_recs], buffer_cf = [From|A#ai.buffer_cf]},
					{noreply,P#dp{wasync = A1, cbstate = State},0};
				OutSql ->
					A1 = A#ai{buffer = [OutSql|A#ai.buffer], buffer_recs = [[]|A#ai.buffer_recs], buffer_cf = [From|A#ai.buffer_cf]},
					{noreply,P#dp{wasync = A1},0}
			end
	end.

% Not a multiactor transaction write
write_call1(#write{sql = Sql,transaction = undefined} = W,From,NewVers,P) ->
	EvNum = P#dp.evnum+1,
	ComplSql = list_to_tuple([<<"#s00;">>|lists:reverse([<<"#s02;#s01;">>|Sql])]),
	ADBW = [[[?EVNUMI,butil:tobin(EvNum)],[?EVTERMI,butil:tobin(P#dp.current_term)]]],
	Records = list_to_tuple([[]|lists:reverse([ADBW|W#write.records])]),
	VarHeader = actordb_sqlprocutil:create_var_header(P),
	?DBG("SQL=~p, Recs=~p",[ComplSql, Records]),
	Res = actordb_sqlite:exec_async(P#dp.db,ComplSql,Records,P#dp.current_term,EvNum,VarHeader),
	A = P#dp.wasync,
	NWB = A#ai{wait = Res, info = W, newvers = NewVers,
		callfrom = [batch,undefined|lists:reverse([undefined|From])], evnum = EvNum, evterm = P#dp.current_term,
		moved = A#ai.buffer_moved,
		buffer_moved = undefined, buffer_nv = undefined, buffer = [], buffer_cf = [], buffer_recs = []},
	P#dp{wasync = NWB};
write_call1(#write{sql = Sql1, transaction = {Tid,Updaterid,Node} = TransactionId} = W,From,NewVers,P) ->
	{_CheckPid,CheckRef} = actordb_sqlprocutil:start_transaction_checker(Tid,Updaterid,Node),
	?DBG("Starting transaction write id ~p, curtr ~p, sql ~p",
				[TransactionId,P#dp.transactionid,Sql1]),
	ForceSync = lists:member(fsync,W#write.flags),
	case P#dp.follower_indexes of
		[] ->
			% If single node cluster, no need to store sql first.
			case P#dp.transactionid of
				TransactionId ->
					% Transaction can write to single actor more than once (especially for KV stores)
					% if we are already in this transaction, just update sql.
					{_OldSql,EvNum,_} = P#dp.transactioninfo,
					case Sql1 of
						delete ->
							ComplSql = <<"delete">>,
							Res = ok;
						_ ->
							ComplSql = Sql1,
							Res = actordb_sqlite:exec(P#dp.db,ComplSql,write)
					end;
				undefined ->
					EvNum = P#dp.evnum+1,
					case Sql1 of
						delete ->
							Res = ok,
							ComplSql = <<"delete">>;
						_ ->
							ComplSql =
								[<<"#s00;">>,
								 actordb_sqlprocutil:semicolon(Sql1),
								 <<"#s02;">>
								 ],
							AWR = [[?EVNUMI,butil:tobin(EvNum)],[?EVTERMI,butil:tobin(P#dp.current_term)]],
							Records = W#write.records++[AWR],
							Res = actordb_sqlite:exec(P#dp.db,ComplSql,Records,write)
					end
			end,
			case actordb_sqlite:okornot(Res) of
				ok ->
					?DBG("Transaction ok"),
					{noreply, actordb_sqlprocutil:reply_maybe(P#dp{transactionid = TransactionId,
								evterm = P#dp.current_term,
								transactioncheckref = CheckRef,force_sync = ForceSync,
								transactioninfo = {ComplSql,EvNum,NewVers},
								callfrom = From, callres = Res},1,[])};
				_Err ->
					ok = actordb_sqlite:rollback(P#dp.db),
					erlang:demonitor(CheckRef),
					?DBG("Transaction not ok ~p",[_Err]),
					{reply,Res,P#dp{activity = make_ref(), transactionid = undefined, evterm = P#dp.current_term}}
			end;
		_ ->
			EvNum = P#dp.evnum+1,
			case P#dp.transactionid of
				TransactionId when Sql1 /= delete ->
					% Rollback prev version of sql.
					ok = actordb_sqlite:rollback(P#dp.db),
					{OldSql,_EvNum,_} = P#dp.transactioninfo,
					% Combine prev sql with new one.
					Sql = iolist_to_binary([OldSql,Sql1]);
				TransactionId ->
					Sql = <<"delete">>;
				_ ->
					case Sql1 of
						delete ->
							Sql = <<"delete">>;
						_ ->
							Sql = iolist_to_binary(Sql1)
					end
			end,
			ComplSql = <<"#s00;#s02;#s03;#s01;">>,
			TransRecs = [[[butil:tobin(Tid),butil:tobin(Updaterid),Node,butil:tobin(NewVers),base64:encode(Sql)]]],
			Records = [[[?EVNUMI,butil:tobin(EvNum)],[?EVTERMI,butil:tobin(P#dp.current_term)]]|TransRecs],
			VarHeader = actordb_sqlprocutil:create_var_header(P),
			ok = actordb_sqlite:okornot(actordb_sqlite:exec(
				P#dp.db,ComplSql,Records,P#dp.current_term,EvNum,VarHeader)),
			{noreply,ae_timer(P#dp{callfrom = From,callres = undefined, evterm = P#dp.current_term,evnum = EvNum,
						  transactioninfo = {Sql,EvNum+1,NewVers},
						  follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
						  transactioncheckref = CheckRef,force_sync = ForceSync,
						  transactionid = TransactionId})}
	end.

update_followers(_Evnum,L) ->
	Now = os:timestamp(),
	[begin
		F#flw{wait_for_response_since = Now}
	end || F <- L].




handle_cast({diepls,_Reason},P) ->
	?DBG("Received diepls ~p",[_Reason]),
	Empty = queue:is_empty(P#dp.callqueue),
	Age = actordb_local:min_ref_age(P#dp.activity),
	CanDie = apply(P#dp.cbmod,cb_candie,[P#dp.mors,P#dp.actorname,P#dp.actortype,P#dp.cbstate]),
	?DBG("Age ~p, verified ~p, empty ~p, candie ~p",[Age,P#dp.verified,Empty,CanDie]),
	case ok of
		_ when Age > 2000, P#dp.verified, Empty, CanDie /= never ->
			{stop,normal,P};
		_ ->
			{noreply,P}
	end;
handle_cast(print_info,P) ->
	?AINF("~p~n",[?R2P(P)]),
	{noreply,P};
handle_cast(Msg,#dp{mors = master, verified = true} = P) ->
	case apply(P#dp.cbmod,cb_cast,[Msg,P#dp.cbstate]) of
		{noreply,S} ->
			{noreply,P#dp{cbstate = S}};
		noreply ->
			{noreply,P}
	end;
handle_cast(_Msg,P) ->
	?INF("sqlproc ~p unhandled cast ~p~n",[P#dp.cbmod,_Msg]),
	{noreply,P}.

% shards/kv can have reads that turn into writes, or have extra data to return along with read.
read_reply(P,[H|T],Pos,Res) ->
	case H of
		{tuple,What,From} ->
			reply(From,{What,actordb_sqlite:exec_res({ok, element(Pos,Res)})});
		{mod,{Mod,Func,Args},From} ->
			case apply(Mod,Func,[P#dp.cbstate,actordb_sqlite:exec_res({ok, element(Pos,Res)})|Args]) of
				{write,Write} ->
					case Write of
						_ when is_binary(Write); is_list(Write) ->
							{noreply,NP,_} = write_call(#write{sql = iolist_to_binary(Write)},From,P);
						{_,_,_} ->
							{noreply,NP,_} = write_call(#write{mfa = Write},From,P)
					end,
					read_reply(NP,T,Pos+1,Res);
				{write,Write,NS} ->
					case Write of
						_ when is_binary(Write); is_list(Write) ->
							{noreply,NP,_} = write_call(#write{sql = iolist_to_binary(Write)},
									   From,P#dp{cbstate = NS});
						{_,_,_} ->
							{noreply,NP,_} = write_call(#write{mfa = Write},From,P#dp{cbstate = NS})
					end,
					read_reply(NP,T,Pos+1,Res);
				{reply_write,Reply,Write,NS} ->
					reply(From,Reply),
					case Write of
						_ when is_binary(Write); is_list(Write) ->
							{noreply,NP,_} = write_call(#write{sql = iolist_to_binary(Write)},undefined,P#dp{cbstate = NS});
						{_,_,_} ->
							{noreply,NP,_} = write_call(#write{mfa = Write},undefined,P#dp{cbstate = NS})
					end,
					read_reply(NP,T,Pos+1,Res);
				{reply,What,NS} ->
					reply(From,What),
					read_reply(P#dp{cbstate = NS},T,Pos+1,Res);
				{reply,What} ->
					reply(From,What),
					read_reply(P,T,Pos+1,Res)
			end;
		From ->
			reply(From,actordb_sqlite:exec_res({ok, element(Pos,Res)})),
			read_reply(P,T,Pos+1,Res)
	end;
read_reply(P,[],_,_) ->
	P.

handle_info(timeout,P) ->
	{noreply,actordb_sqlprocutil:doqueue(P)};
% Unlike writes we can reply directly
handle_info({Ref,Res}, #dp{rasync = #ai{wait = Ref} = BD} = P) when is_reference(Ref) ->
	NewBD = BD#ai{callfrom = undefined, info = undefined, wait = undefined},
	case Res of
		{ok,ResTuples} ->
			?DBG("Read resp=~p",[Res]),
			{noreply,read_reply(P#dp{rasync = NewBD}, BD#ai.callfrom, 1, ResTuples)};
		Err ->
			?ERR("Read call error: ~p",[Err]),
			{noreply,P#dp{rasync = NewBD}}
	end;
% async write result
handle_info({Ref,Res1}, #dp{wasync = #ai{wait = Ref} = BD} = P) when is_reference(Ref) ->
	?DBG("Write result ~p",[Res1]),
	Res = actordb_sqlite:exec_res(Res1),
	From = BD#ai.callfrom,
	EvNum = BD#ai.evnum,
	EvTerm = BD#ai.evterm,
	NewVers = BD#ai.newvers,
	Moved = BD#ai.moved,
	W = BD#ai.info,
	ForceSync = lists:member(fsync,W#write.flags),
	NewAsync = BD#ai{callfrom = undefined, evnum = undefined, evterm = undefined,
		newvers = undefined, info = undefined, wait = undefined},
	case actordb_sqlite:okornot(Res) of
		ok ->
			case ok of
				_ when P#dp.follower_indexes == [] ->
					{noreply,actordb_sqlprocutil:statequeue(actordb_sqlprocutil:reply_maybe(
						P#dp{callfrom = From, callres = Res,evnum = EvNum,
							flags = P#dp.flags band (bnot ?FLAG_SEND_DB),
							netchanges = actordb_local:net_changes(), force_sync = ForceSync,
							schemavers = NewVers,evterm = EvTerm,movedtonode = Moved,
							wasync = NewAsync},1,[]))};
				_ ->
					% reply on appendentries response or later if nodes are behind.
					case P#dp.callres of
						undefined ->
							Callres = Res;
						Callres ->
							ok
					end,
					{noreply, actordb_sqlprocutil:statequeue(ae_timer(P#dp{callfrom = From, callres = Callres,
						flags = P#dp.flags band (bnot ?FLAG_SEND_DB),
						follower_indexes = update_followers(EvNum,P#dp.follower_indexes),
						netchanges = actordb_local:net_changes(),force_sync = ForceSync,
						evterm = EvTerm, evnum = EvNum,schemavers = NewVers,movedtonode = Moved,
						wasync = NewAsync}))}
			end;
		Resp when EvNum == 1 ->
			% Restart with write but just with schema.
			actordb_sqlite:rollback(P#dp.db),
			reply(From,Resp),
			PES = actordb_sqlprocutil:post_election_sql(
				P#dp{schemavers = undefined, wasync = NewAsync},[],undefined,[],undefined),
			{NP,SchemaSql,SchemaRecords,_} = PES,
			NW = W#write{sql = SchemaSql, records = SchemaRecords},
			write_call1(NW,undefined,NP#dp.schemavers,NP);
		Resp ->
			actordb_sqlite:rollback(P#dp.db),
			reply(From,Resp),
			{noreply,actordb_sqlprocutil:statequeue(P#dp{wasync = NewAsync})}
	end;
handle_info(doqueue, P) ->
	{noreply,actordb_sqlprocutil:doqueue(P)};
handle_info({'DOWN',Monitor,_,PID,Reason},P) ->
	down_info(PID,Monitor,Reason,P);
handle_info(doelection,P) ->
	self() ! doelection1,
	{noreply,P};
handle_info({doelection,LatencyBefore,TimerFrom},P) ->
	LatencyNow = actordb_latency:latency(),
	% Delay if latency significantly increased since start of timer.
	% But only if more than 100ms latency. Which should mean significant load or bad network which
	%  from here means same thing.
	case LatencyNow > (LatencyBefore*1.5) andalso LatencyNow > 100 of
		true ->
			{noreply,P#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		false ->
			case [F || F <- P#dp.follower_indexes, F#flw.last_seen > TimerFrom] of
				[] ->
					% Clear out msg queue first.
					self() ! doelection1,
					{noreply,P};
				_ ->
					{noreply,P#dp{election = actordb_sqlprocutil:election_timer(undefined)}}
			end
	end;
handle_info(doelection1,P) ->
	Empty = queue:is_empty(P#dp.callqueue),
	?DBG("Election timeout, master=~p, verified=~p, followers=~p",
		[P#dp.masternode,P#dp.verified,P#dp.follower_indexes]),
	case ok of
		_ when P#dp.verified, P#dp.mors == master, P#dp.dbcopy_to /= [] ->
			% Do not run elections while db is being copied
			{noreply,P#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		_ when P#dp.verified, P#dp.mors == master ->
			RSY = actordb_sqlprocutil:check_for_resync(P,P#dp.follower_indexes,synced),
			?DBG("Election timer action ~p",[RSY]),
			case RSY of
				synced when P#dp.movedtonode == deleted ->
					?DBG("Stopping because deleted"),
					% actordb_sqlprocutil:delete_actor(P),
					{stop,normal,P};
				synced ->
					{noreply,P#dp{election = undefined}};
				resync ->
					{noreply,actordb_sqlprocutil:start_verify(P#dp{election = undefined},false)};
				wait_longer ->
					{noreply,P#dp{election = erlang:send_after(3000,self(),doelection)}};
				timer ->
					{noreply,P#dp{election = actordb_sqlprocutil:election_timer(undefined)}}
			end;
		_ when Empty; is_pid(P#dp.election); P#dp.masternode /= undefined;
					P#dp.flags band ?FLAG_NO_ELECTION_TIMEOUT > 0 ->
			case P#dp.masternode /= undefined andalso P#dp.masternode /= actordb_conf:node_name() andalso
					bkdcore_rpc:is_connected(P#dp.masternode) of
				true ->
					?DBG("Election timeout, do nothing, master=~p",[P#dp.masternode]),
					{noreply,P#dp{without_master_since = undefined}};
				false when P#dp.without_master_since == undefined ->
					?DBG("Election timeout, master=~p, election=~p, empty=~p, me=~p",
						[P#dp.masternode,P#dp.election,Empty,actordb_conf:node_name()]),
					NP = P#dp{election = undefined,without_master_since = os:timestamp()},
					{noreply,actordb_sqlprocutil:start_verify(NP,false)};
				false ->
					?DBG("Election timeout, master=~p, election=~p, empty=~p, me=~p",
						[P#dp.masternode,P#dp.election,Empty,actordb_conf:node_name()]),
					Now = os:timestamp(),
					case timer:now_diff(Now,P#dp.without_master_since) >= 3000000 of
						true when Empty == false ->
							A = P#dp.wasync,
							actordb_sqlprocutil:empty_queue(P#dp.wasync, P#dp.callqueue,{error,consensus_timeout}),
							A1 = A#ai{buffer = [], buffer_recs = [], buffer_cf = [],
							buffer_nv = undefined, buffer_moved = undefined},
							{noreply,actordb_sqlprocutil:start_verify(
								P#dp{callqueue = queue:new(),election = undefined,wasync = A1},false)};
						_ ->
							{noreply,actordb_sqlprocutil:start_verify(P#dp{election = undefined},false)}
					end
			end;
		_ ->
			?DBG("Election timeout"),
			{noreply,actordb_sqlprocutil:start_verify(P#dp{election = undefined},false)}
	end;
handle_info(retry_copy,P) ->
	?DBG("Retry copy"),
	case P#dp.mors == master andalso P#dp.verified == true of
		true ->
			{noreply,actordb_sqlprocutil:retry_copy(P)};
		_ ->
			{noreply, P}
	end;
handle_info(check_locks,P) ->
	case P#dp.locked of
		[] ->
			{noreply,P};
		_ ->
			erlang:send_after(1000,self(),check_locks),
			{noreply, actordb_sqlprocutil:check_locks(P,P#dp.locked,[])}
	end;
handle_info(stop,P) ->
	?DBG("Received stop msg"),
	handle_info({stop,normal},P);
handle_info({stop,Reason},P) ->
	?DBG("Actor stop with reason ~p",[Reason]),
	{stop, normal, P};
handle_info(print_info,P) ->
	handle_cast(print_info,P);
handle_info(commit_transaction,P) ->
	down_info(0,12345,done,P#dp{transactioncheckref = 12345});
handle_info(start_copy,P) ->
	?DBG("Start copy ~p",[P#dp.copyfrom]),
	case P#dp.copyfrom of
		{move,NewShard,Node} ->
			OldActor = P#dp.actorname,
			Msg = {move,NewShard,actordb_conf:node_name(),P#dp.copyreset,P#dp.cbstate};
		{split,MFA,Node,OldActor,NewActor} ->
			% Change node to this node, so that other actor knows where to send db.
			Msg = {split,MFA,actordb_conf:node_name(),OldActor,NewActor,P#dp.copyreset,P#dp.cbstate};
		{Node,OldActor} ->
			Msg = {copy,{actordb_conf:node_name(),OldActor,P#dp.actorname}}
	end,
	Home = self(),
	spawn(fun() ->
		Rpc = {?MODULE,call,[{OldActor,P#dp.actortype},[],Msg,P#dp.cbmod,onlylocal]},
		case actordb:rpc(Node,OldActor,Rpc) of
			ok ->
				?DBG("Ok response for startcopy msg"),
				ok;
			{ok,_} ->
				?DBG("Ok response for startcopy msg"),
				ok;
			{redirect,_} ->
				?DBG("Received redirect, presume job is done"),
				Home ! start_copy_done;
			Err ->
				?ERR("Unable to start copy from ~p, ~p",[P#dp.copyfrom,Err]),
				Home ! {stop,Err}
		end
	end),
	{noreply,P};
handle_info(start_copy_done,P) ->
	{ok,NP} = init(P,copy_done),
	{noreply,NP};
handle_info(Msg,#dp{verified = true} = P) ->
	case apply(P#dp.cbmod,cb_info,[Msg,P#dp.cbstate]) of
		{noreply,S} ->
			{noreply,P#dp{cbstate = S}};
		noreply ->
			{noreply,P}
	end;
handle_info(_Msg,P) ->
	?DBG("sqlproc ~p unhandled info ~p~n",[P#dp.cbmod,_Msg]),
	{noreply,P}.



down_info(PID,_Ref,Reason,#dp{election = PID} = P1) ->
	case Reason of
		noproc ->
			{noreply, P1#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		{failed,Err} ->
			P = P1,
			?ERR("Election failed, retrying later ~p",[Err]),
			{noreply, P#dp{election = actordb_sqlprocutil:election_timer(undefined)}};
		{leader,_,_} when (P1#dp.flags band ?FLAG_CREATE) == 0, P1#dp.movedtonode == deleted ->
			P = P1,
			?INF("Stopping with nocreate ",[]),
			{stop,nocreate,P1};
		% We are leader, evnum == 0, which means no other node has any data.
		% If create flag not set stop.
		{leader,_,_} when (P1#dp.flags band ?FLAG_CREATE) == 0, P1#dp.schemavers == undefined ->
			P = P1,
			?INF("Stopping with nocreate ",[]),
			{stop,nocreate,P1};
		{leader,NewFollowers,AllSynced} ->
			actordb_local:actor_mors(master,actordb_conf:node_name()),
			P = actordb_sqlprocutil:reopen_db(P1#dp{mors = master, election = undefined,
				masternode = actordb_conf:node_name(),
				without_master_since = undefined,
				masternodedist = bkdcore:dist_name(actordb_conf:node_name()),
				flags = P1#dp.flags band (bnot ?FLAG_WAIT_ELECTION),
				locked = lists:delete(ae,P1#dp.locked)}),
			case P#dp.movedtonode of
				deleted ->
					SqlIn = (actordb_sqlprocutil:actually_delete(P1))#write.sql,
					Moved = undefined,
					SchemaVers = undefined;
				_ ->
					SqlIn = [],
					Moved = P#dp.movedtonode,
					SchemaVers = P#dp.schemavers
			end,
			ReplType = apply(P#dp.cbmod,cb_replicate_type,[P#dp.cbstate]),
			?DBG("Elected leader term=~p, nodes_synced=~p, moved=~p",
				[P1#dp.current_term,AllSynced,P#dp.movedtonode]),
			ReplBin = term_to_binary({P#dp.cbmod,P#dp.actorname,P#dp.actortype,P#dp.current_term}),
			ok = actordb_sqlite:replicate_opts(P#dp.db,ReplBin,ReplType),

			case P#dp.schemavers of
				undefined ->
					Transaction = [],
					Rows = [];
				_ ->
					case actordb_sqlite:exec(P#dp.db,
							<<"SELECT * FROM __adb;",
							  "SELECT * FROM __transactions;">>,read) of
						{ok,[[{columns,_},{rows,Transaction}],
						     [{columns,_},{rows,Rows}]]} ->
						     	ok;
						Err ->
							?ERR("Unable read from db for, error=~p after election.",[Err]),
							Transaction = Rows = [],
							exit(error)
					end
			end,

			case butil:ds_val(?COPYFROMI,Rows) of
				CopyFrom1 when byte_size(CopyFrom1) > 0 ->
					{CopyFrom,CopyReset,CbState} = binary_to_term(base64:decode(CopyFrom1));
				_ ->
					CopyFrom = CopyReset = undefined,
					CbState = P#dp.cbstate
			end,
			% After election is won a write needs to be executed. What we will write depends on the situation:
			%  - If this actor has been moving, do a write to clean up after it (or restart it)
			%  - If transaction active continue with write.
			%  - If empty db or schema not up to date create/update it.
			%  - It can also happen that both transaction active and actor move is active. Sqls will be combined.
			%  - Otherwise just empty sql, which still means an increment for evnum and evterm in __adb.
			NP1 = P#dp{verified = true,copyreset = CopyReset,movedtonode = Moved,
				cbstate = CbState, schemavers = SchemaVers},
			{NP,Sql,AdbRecords,Callfrom} =
				actordb_sqlprocutil:post_election_sql(NP1,Transaction,CopyFrom,SqlIn,P#dp.callfrom),
			% If nothing to store and all nodes synced, send an empty AE.
			case is_atom(Sql) == false andalso iolist_size(Sql) == 0 of
				true when AllSynced, NewFollowers == [] ->
					?DBG("Nodes synced, no followers"),
					W = NP#dp.wasync,
					{noreply,actordb_sqlprocutil:doqueue(actordb_sqlprocutil:do_cb(
						NP#dp{follower_indexes = [],netchanges = actordb_local:net_changes(),
						wasync = W#ai{nreplies = W#ai.nreplies+1}}))};
				true when AllSynced ->
					?DBG("Nodes synced, running empty AE."),
					NewFollowers1 = [actordb_sqlprocutil:send_empty_ae(P,NF) || NF <- NewFollowers],
					W = NP#dp.wasync,
					{noreply,ae_timer(NP#dp{callres = ok,follower_indexes = NewFollowers1,
						wasync = W#ai{nreplies = W#ai.nreplies+1},
						netchanges = actordb_local:net_changes()}), 0};
				_ ->
					?DBG("Running post election write on nodes ~p, evterm=~p, curterm=~p, withdb ~p, vers ~p",
						[P#dp.follower_indexes,P#dp.evterm,P#dp.current_term,
						NP#dp.flags band ?FLAG_SEND_DB > 0,NP#dp.schemavers]),
					W = #write{sql = Sql, transaction = NP#dp.transactionid,records = AdbRecords},
					write_call(W,Callfrom, NP)
			end;
		follower ->
			P = P1,
			?DBG("Continue as follower"),
			{noreply,actordb_sqlprocutil:reopen_db(P#dp{
				election = actordb_sqlprocutil:election_timer(undefined),
				masternode = undefined, mors = slave, without_master_since = os:timestamp()}), 0};
		_Err ->
			P = P1,
			?ERR("Election invalid result ~p",[_Err]),
			{noreply, P#dp{election = actordb_sqlprocutil:election_timer(undefined)}, 0}
	end;
down_info(_PID,Ref,Reason,#dp{transactioncheckref = Ref} = P) ->
	?DBG("Transactioncheck died ~p myid ~p",[Reason,P#dp.transactionid]),
	case P#dp.transactionid of
		{Tid,Updaterid,Node} ->
			case Reason of
				noproc ->
					{_CheckPid,CheckRef} = actordb_sqlprocutil:start_transaction_checker(Tid,Updaterid,Node),
					{noreply,P#dp{transactioncheckref = CheckRef}};
				abandoned ->
					case handle_call({commit,false,P#dp.transactionid},
							undefined,P#dp{transactioncheckref = undefined}) of
						{stop,normal,NP} ->
							{stop,normal,NP};
						{reply,_,NP} ->
							{noreply,NP};
						{noreply,NP} ->
							{noreply,NP}
					end;
				done ->
					case handle_call({commit,true,P#dp.transactionid},
							undefined,P#dp{transactioncheckref = undefined}) of
						{stop,normal,NP} ->
							{stop,normal,NP};
						{reply,_,NP} ->
							{noreply,NP};
						{noreply,NP} ->
							{noreply,NP}
					end
			end;
		_ ->
			{noreply,P#dp{transactioncheckref = undefined}}
	end;
down_info(PID,_Ref,Reason,#dp{copyproc = PID} = P) ->
	?DBG("copyproc died ~p my_status=~p copyfrom=~p",[Reason,P#dp.mors,P#dp.copyfrom]),
	case Reason of
		unlock ->
			case catch actordb_sqlprocutil:callback_unlock(P) of
				ok when is_binary(P#dp.copyfrom) ->
					{ok,NP} = init(P#dp{mors = slave},copyproc_done),
					{noreply,NP};
				ok ->
					{ok,NP} = init(P#dp{mors = master},copyproc_done),
					{noreply,NP};
				Err ->
					?DBG("Unable to unlock"),
					{stop,Err,P}
			end;
		ok when P#dp.mors == slave ->
			?DBG("Stopping because slave"),
			{stop,normal,P};
		nomajority ->
			{stop,{error,nomajority},P};
		% Error copying.
		%  - There is a chance copy succeeded. If this node was able to send unlock msg
		%    but connection was interrupted before replying.
		%    If this is the case next read/write call will start
		%    actor on this node again and everything will be fine.
		%  - If copy failed before unlock, then it actually did fail. In that case move will restart
		%    eventually.
		_ ->
			?ERR("Coproc died with error ~p~n",[Reason]),
			% actordb_sqlprocutil:empty_queue(P#dp.callqueue,{error,copyfailed}),
			{stop,{error,copyfailed},P}
	end;
down_info(PID,_Ref,Reason,P) ->
	case lists:keyfind(PID,#cpto.pid,P#dp.dbcopy_to) of
		false ->
			?DBG("downmsg, verify maybe? ~p",[P#dp.election]),
			case apply(P#dp.cbmod,cb_info,[{'DOWN',_Ref,process,PID,Reason},P#dp.cbstate]) of
				{noreply,S} ->
					{noreply,P#dp{cbstate = S}};
				noreply ->
					{noreply,P}
			end;
		C ->
			?DBG("Down copyto proc ~p ~p ~p ~p ~p",
				[P#dp.actorname,Reason,C#cpto.ref,P#dp.locked,P#dp.dbcopy_to]),
			case Reason of
				ok ->
					ok;
				_ ->
					?ERR("Copyto process invalid exit ~p",[Reason])
			end,
			WithoutCopy = lists:keydelete(PID,#lck.pid,P#dp.locked),
			NewCopyto = lists:keydelete(PID,#cpto.pid,P#dp.dbcopy_to),
			false = lists:keyfind(C#cpto.ref,2,WithoutCopy),
			% wait_copy not in list add it (2nd stage of lock)
			WithoutCopy1 =  [#lck{ref = C#cpto.ref, ismove = C#cpto.ismove,
								node = C#cpto.node,time = os:timestamp(),
								actorname = C#cpto.actorname}|WithoutCopy],
			erlang:send_after(1000,self(),check_locks),
			NP = P#dp{dbcopy_to = NewCopyto,
						locked = WithoutCopy1,
						activity = make_ref()},
			case queue:is_empty(P#dp.callqueue) of
				true ->
					{noreply,NP};
				false ->
					handle_info(doqueue,NP)
			end
	end.


terminate(Reason, P) ->
	?DBG("Terminating ~p",[Reason]),
	actordb_sqlite:stop(P#dp.db),
	distreg:unreg(self()),
	ok.
code_change(_, P, _) ->
	{ok, P}.
init(#dp{} = P,_Why) ->
	% ?DBG("Reinit because ~p, ~p, ~p",[_Why,?R2P(P),get()]),
	?DBG("Reinit because ~p",[_Why]),
	actordb_sqlite:stop(P#dp.db),
	Flags = P#dp.flags band (bnot ?FLAG_WAIT_ELECTION) band (bnot ?FLAG_STARTLOCK),
	case ok of
		_ when is_reference(P#dp.election) ->
			erlang:cancel_timer(P#dp.election);
		_ when is_pid(P#dp.election) ->
			exit(P#dp.election,reinit);
		_ ->
		 	ok
	end,
	init([{actor,P#dp.actorname},{type,P#dp.actortype},{mod,P#dp.cbmod},{flags,Flags},
		{state,P#dp.cbstate},{slave,P#dp.mors == slave},{wasync,P#dp.wasync},{rasync,P#dp.rasync},
		{queue,P#dp.callqueue},{startreason,{reinit,_Why}}]).
% Never call other processes from init. It may cause deadlocks. Whoever
% started actor is blocking waiting for init to finish.
init([_|_] = Opts) ->
	% put(opt,Opts),
	% Random needs to be unique per-node, not per-actor.
	random:seed(actordb_conf:cfgtime()),
	Now = os:timestamp(),
	P1 = #dp{mors = master, callqueue = queue:new(),statequeue = queue:new(), without_master_since = Now,
		schemanum = catch actordb_schema:num()},
	case actordb_sqlprocutil:parse_opts(P1,Opts) of
		{registered,Pid} ->
			explain({registered,Pid},Opts),
			{stop,normal};
		% P when (P#dp.flags band ?FLAG_ACTORNUM) > 0 ->
		% 	explain({actornum,P#dp.fullpath,actordb_sqlprocutil:read_num(P)},Opts),
		% 	{stop,normal};
		P when (P#dp.flags band ?FLAG_EXISTS) > 0 ->
			case P#dp.movedtonode of
				deleted ->
					explain({ok,[{columns,{<<"exists">>}},{rows,[{<<"false">>}]}]},Opts);
				_ ->
					% {ok,_Db,SchemaTables,_PageSize} = actordb_sqlite:init(P#dp.dbpath,wal),
					% explain({ok,[{columns,{<<"exists">>}},{rows,[{butil:tobin(SchemaTables /= [])}]}]},Opts),
					% {stop,normal}
					LocalShard = actordb_shardmngr:find_local_shard(P#dp.actorname,P#dp.actortype),
					Val =
					case LocalShard of
						{redirect,Shard,Node} ->
							actordb:rpc(Node,Shard,{actordb_shard,is_reg,[Shard,P#dp.actorname,P#dp.actortype]});
						undefined ->
							{Shard,_,Node} = actordb_shardmngr:find_global_shard(P#dp.actorname),
							actordb:rpc(Node,Shard,{actordb_shard,is_reg,[Shard,P#dp.actorname,P#dp.actortype]});
						Shard ->
							actordb_shard:is_reg(Shard,P#dp.actorname,P#dp.actortype)
					end,
					explain({ok,[{columns,{<<"exists">>}},{rows,[{butil:tobin(Val)}]}]},Opts),
					{stop,normal}
			end;
		P when (P#dp.flags band ?FLAG_STARTLOCK) > 0 ->
			case lists:keyfind(lockinfo,1,Opts) of
				{lockinfo,dbcopy,{Ref,CbState,CpFrom,CpReset}} ->
					?DBG("Starting actor slave lock for copy on ref ~p",[Ref]),
					{ok,Db,_,_PageSize} = actordb_sqlite:init(P#dp.dbpath,wal),
					{ok,Pid} = actordb_sqlprocutil:start_copyrec(
						P#dp{db = Db, mors = slave, cbstate = CbState,
							dbcopyref = Ref,  copyfrom = CpFrom, copyreset = CpReset}),
					{ok,P#dp{copyproc = Pid, verified = false,mors = slave, copyfrom = P#dp.copyfrom}};
				{lockinfo,wait} ->
					?DBG("Starting actor lock wait ~p",[P]),
					{ok,P}
			end;
		P when P#dp.copyfrom == undefined ->
			?DBG("Actor start, copy=~p, flags=~p, mors=~p startreason=~p",[P#dp.copyfrom,
							P#dp.flags,P#dp.mors,false]), %butil:ds_val(startreason,Opts)
			% Could be normal start after moving to another node though.
			MovedToNode = apply(P#dp.cbmod,cb_checkmoved,[P#dp.actorname,P#dp.actortype]),
			RightCluster = lists:member(MovedToNode,bkdcore:all_cluster_nodes()),
			case actordb_driver:actor_info(P#dp.dbpath,actordb_util:hash(P#dp.dbpath)) of
				% {_,VotedFor,VotedCurrentTerm,VoteEvnum,VoteEvTerm} ->
				{{_FCT,LastCheck},{VoteEvTerm,VoteEvnum},_InProg,_MxPage,_AllPages,VotedCurrentTerm,<<>>} ->
					VotedFor = undefined;
				{{_FCT,LastCheck},{VoteEvTerm,VoteEvnum},_InProg,_MxPage,_AllPages,VotedCurrentTerm,VotedFor} ->
					ok;
				_ ->
					VotedFor = undefined,
					LastCheck = VoteEvnum = VotedCurrentTerm = VoteEvTerm = 0
			end,
			case ok of
				_ when P#dp.mors == slave ->
					{ok,actordb_sqlprocutil:init_opendb(P#dp{current_term = VotedCurrentTerm,
					voted_for = VotedFor, evnum = VoteEvnum,evterm = VoteEvTerm,
					last_checkpoint = LastCheck})};
				_ when MovedToNode == undefined; RightCluster ->
					NP = P#dp{current_term = VotedCurrentTerm,voted_for = VotedFor, evnum = VoteEvnum,
							evterm = VoteEvTerm, last_checkpoint = LastCheck},
					{ok,actordb_sqlprocutil:start_verify(actordb_sqlprocutil:init_opendb(NP),true)};
				_ ->
					?DBG("Actor moved ~p ~p ~p",[P#dp.actorname,P#dp.actortype,MovedToNode]),
					{ok, P#dp{verified = true, movedtonode = MovedToNode}}
			end;
		{stop,Explain} ->
			explain(Explain,Opts),
			{stop,normal};
		P ->
			self() ! start_copy,
			{ok,P#dp{mors = master}}
	end;
init(#dp{} = P) ->
	init(P,noreason).



explain(What,Opts) ->
	case lists:keyfind(start_from,1,Opts) of
		{_,{FromPid,FromRef}} ->
			FromPid ! {FromRef,What};
		_ ->
			ok
	end.

reply(A,B) ->
	actordb_sqlprocutil:reply(A,B).
% reply(undefined,_Msg) ->
% 	ok;
% reply([_|_] = From,Msg) ->
% 	[gen_server:reply(F,Msg) || F <- From];
% reply(From,Msg) ->
% 	gen_server:reply(From,Msg).


ae_timer(P) ->
	P#dp{election = actordb_sqlprocutil:election_timer(P#dp.election)}.
	% case P#dp.resend_ae_timer of
	% 	undefined ->
	% 		P#dp{resend_ae_timer = erlang:send_after(300,self(),{ae_timer,P#dp.evnum})};
	% 	_ ->
	% 		P
	% end.
