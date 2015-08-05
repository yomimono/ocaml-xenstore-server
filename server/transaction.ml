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
open Sexplib.Std
open Lwt

let debug fmt = Logging.debug "transaction" fmt
open Xenstore
open Persistence

let none = 0l
let test_eagain = ref false

type 'view side_effects = {
  view: (module VIEW with type t = 'view);

  (* A log of all the store updates in this transaction. When the transaction
     is committed, these paths need to be committed to stable storage.
     The list is stored in reverse order for constant-{time,space} append. *)
  mutable updates: Store.update list;
  (* A log of updates which should generate a watch events. Note this can't
     be derived directly from [updates] above because implicit directory
     creates don't generate watches (for no good reason) *)
  mutable watches: (Protocol.Op.t * Protocol.Name.t) list;
  (* A list of introduced domains *)
  mutable domains: Domain.address list;
  (* A list of all new watches registered during the transaction *)
  mutable watch: (Protocol.Name.t * string) list;
  (* A list of all the watches unregistered during the transaction *)
  mutable unwatch: (Protocol.Name.t * string) list;
} (*with sexp*)

let no_side_effects () =
  view >>= fun view ->
  return { view; updates = []; watches = []; domains = []; watch = []; unwatch = [] }

let merge a b = {
  view = a.view;
  updates = a.updates @ b.updates;
  watches = a.watches @ b.watches;
  domains = a.domains @ b.domains;
  watch   = a.watch   @ b.watch;
  unwatch = a.unwatch @ b.unwatch;
}

let ( ++ ) a b = merge a b

let get_watches side_effects = List.rev side_effects.watches
let get_updates side_effects = List.rev side_effects.updates
let get_domains side_effects = List.rev side_effects.domains
let get_watch   side_effects = List.rev side_effects.watch
let get_unwatch side_effects = List.rev side_effects.unwatch

type 'view t = {
  (* True if all side-effects are published immediately, false if we're
     in a throwaway transaction context. *)
  immediate: bool;
  id: int32;
  store: Store.t;
  (* Side-effects which should be generated when the transaction is committed. *)
  side_effects: 'view side_effects;
  (* A log of all the requests and responses during this transaction. When
     committing a transaction to a modified store, we replay the requests and
     abort the transaction if any of the responses would now be different. *)
  mutable operations: (Protocol.Request.t * Protocol.Response.t) list;
}

let make id store =
  no_side_effects () >>= fun side_effects ->
  return {
    id; immediate = id = none;
    store = if id = none then store else Store.copy store;
    side_effects;
    operations = [];
  }

let take_snapshot store =
  no_side_effects () >>= fun side_effects ->
  return {
    id = none; immediate = false;
    store = Store.copy store;
    side_effects;
    operations = [];
  }

let get_id t = t.id
let get_immediate t = t.immediate
let get_store t = t.store
let get_side_effects t = t.side_effects

let watchevent t ty path =
  if t.immediate then t.side_effects.watches <- (ty, Protocol.Name.Absolute path) :: t.side_effects.watches

let add_operation t request response =
  if not t.immediate then t.operations <- (request, response) :: t.operations

let watch t name token =
  if t.immediate then t.side_effects.watch <- (name, token) :: t.side_effects.watch

let unwatch t name token =
  if t.immediate then t.side_effects.unwatch <- (name, token) :: t.side_effects.unwatch

let get_operations t = List.rev t.operations

let mkdir t limits creator perm path =
  if not (Store.exists t.store path) then (
    Protocol.Path.iter (fun prefix ->
        if not(Store.exists t.store prefix) then begin
          let update = Store.mkdir t.store limits creator perm prefix in
          if t.immediate then t.side_effects.updates <- update :: t.side_effects.updates;
          (* no watches for implicitly created directories *)
        end
      ) path;
    watchevent t Protocol.Op.Mkdir path
  )

let write t limits creator perm path value =
  mkdir t limits creator perm (Protocol.Path.dirname path);
  let update = Store.write t.store limits creator perm path value in
  if t.immediate then t.side_effects.updates <- update :: t.side_effects.updates;
  watchevent t Protocol.Op.Write path

let setperms t perm path perms =
  let update = Store.setperms t.store perm path perms in
  if t.immediate then t.side_effects.updates <- update :: t.side_effects.updates;
  watchevent t Protocol.Op.Setperms path

let rm t perm path =
  let updates = Store.rm t.store perm path in
  if t.immediate then t.side_effects.updates <- updates @ t.side_effects.updates;
  watchevent t Protocol.Op.Rm path

let exists t perms path = Store.exists t.store path
let ls t perm path = Store.ls t.store perm path
let read t perm path = Store.read t.store perm path
let getperms t perm path = Store.getperms t.store perm path
