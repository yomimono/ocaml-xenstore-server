(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Lwt
open Printf
open Sexplib
open Xenstore

type logger = {
	stream: string Lwt_stream.t;
	push: string -> unit;
	elements: int ref;
	max_elements: int;
	dropped_elements: int ref;
}

let create max_elements =
	let elements = ref (ref 0) in
	let dropped_elements = ref (ref 0) in
	let stream, stream_push = Lwt_stream.create () in
	let push line =
		if !(!elements) > max_elements then begin
			incr !dropped_elements
		end else begin
			stream_push (Some line);
			incr !elements
		end in
	{
		stream = stream;
		push = push;
		elements = !elements;
		max_elements = max_elements;
		dropped_elements = !dropped_elements;
	}

let get (logger: logger) =
	let return_lines all =
		logger.elements := !(logger.elements) - (List.length all);
		let dropped = !(logger.dropped_elements) in
		logger.dropped_elements := 0;
		return (if dropped <> 0
			then Printf.sprintf "<-- dropped %d log lines" dropped :: all
			else all) in

	(* Grab as many elements as we can without blocking *)
	let all = Lwt_stream.get_available logger.stream in
	if all <> []
	then return_lines all
	else begin
		(* Block for at least one line *)
		lwt all = Lwt_stream.nget 1 logger.stream in
		return_lines all
	end

(* General system logging *)
let logger = create 512

(* Operation logging *)
let access_logger = create 512

type level = Debug | Info | Warn | Error | Null

let log_level = ref Warn

let int_of_level = function
	| Debug -> 0 | Info -> 1 | Warn -> 2
	| Error -> 3 | Null -> max_int

let string_of_level = function
	| Debug -> "debug" | Info -> "info" | Warn -> "warn"
	| Error -> "error" | Null -> "null"

let log level key (fmt: (_,_,_,_) format4) =
	let level = string_of_level level in
	Printf.ksprintf logger.push ("[%5s|%s] " ^^ fmt) level key

let debug key = log Debug key
let info key = log Info key
let warn key = log Warn key
let error key = log Error key

(* Access logger *)

type access_type =
	| Conflict
	| Commit
	| Newconn
	| Endconn
	| Debug of string
	| Start_transaction
	| End_transaction
	| Request of Protocol.Request.t
	| Response of Protocol.Response.t * string option

let string_of_tid ~con tid =
	if tid = 0l
	then sprintf "%-12s" con
	else sprintf "%-12s" (sprintf "%s.%li" con tid)

let string_of_access_type = function
	| Conflict                -> "conflict "
	| Commit                  -> "commit   "
	| Newconn                 -> "newconn  "
	| Endconn                 -> "endconn  "
	| Debug x                 -> "         " ^ x
	| Start_transaction       -> "t start  "
	| End_transaction         -> "t end    "
	| Request r               -> " <- in   " ^ (Sexp.to_string_hum (Protocol.Request.sexp_of_t r))
	| Response (r, info_opt)  -> " -> out  " ^ (Sexp.to_string_hum (Protocol.Response.sexp_of_t r)) ^ (match info_opt with Some x -> " (" ^ x ^ ")" | None -> "")

let disable_conflict = ref false
let disable_commit = ref false
let disable_newconn = ref false
let disable_endconn = ref false
let disable_transaction = ref false

let disable_request = ref [ Protocol.Op.Read ]
let disable_reply_ok = ref (List.filter (fun x -> x <> Protocol.Op.Watchevent) Protocol.Op.all)
let disable_reply_err = ref [ "read" ]

let access_type_disabled = function
	| Conflict -> !disable_conflict
	| Commit   -> !disable_commit
	| Newconn  -> !disable_newconn
	| Endconn  -> !disable_endconn
	| Debug _  -> false
	| Start_transaction
	| End_transaction   -> !disable_transaction
	| Request r -> List.mem (Protocol.Request.get_ty r) !disable_request
	| Response (r, _) ->
		begin match r with
			| Protocol.Response.Error x ->
				List.mem x !disable_reply_err
			| _ ->
				List.mem (Protocol.Response.get_ty r) !disable_reply_ok
		end

let access_type_enabled x = not(access_type_disabled x)

let sanitize_data data =
	let data = String.copy data in
	for i = 0 to String.length data - 1
	do
		if data.[i] = '\000' then
			data.[i] <- ' '
	done;
	String.escaped data

let access_logging ~con ~tid ?(data="") access_type =
	if access_type_enabled access_type then begin
		let tid = string_of_tid ~con tid in
		let access_type = string_of_access_type access_type in
		let data = sanitize_data data in
		Printf.ksprintf logger.push "%s %s %s" tid access_type data
	end

let new_connection = access_logging Newconn
let end_connection = access_logging Endconn
let conflict = access_logging Conflict
let commit = access_logging Commit

let request ~tid ~con request = access_logging ~tid ~con (Request request)
let response ~tid ~con ?info response = access_logging ~tid ~con (Response(response, info))
let debug_print ~tid ~con x = access_logging ~tid ~con (Debug x)

let start_transaction ~tid ~con = access_logging ~tid ~con (Start_transaction)
let end_transaction ~tid ~con = access_logging ~tid ~con (End_transaction)
