
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 General representation of Clauses} *)

open Libzipperposition

(** An arbitrary clause, typically obtained from the input or by
    instantiation *)
type t = Hornet_types.clause
type clause = t

type horn_clause = Hornet_types.horn_clause
type bool_lit = Hornet_types.bool_lit
type idx = Hornet_types.clause_idx
type proof = Hornet_types.proof

(* constraint on the literals *)
type constraint_ = Hornet_types.c_constraint_ =
  | C_dismatch of Dismatching_constr.t

(** How to build a clause from a ['a] and other parameters *)
type 'a builder =
  ?b_lit:bool_lit lazy_t ->
  ?constrs:constraint_ list ->
  'a ->
  proof ->
  t

val make : Lit.t IArray.t builder
val make_l : Lit.t list builder

val proof : t -> proof
val lits : t -> Lit.t IArray.t
val bool_lit : t -> bool_lit lazy_t option
val constr : t -> constraint_ list

val dismatch_constr : t -> Dismatching_constr.t list

val is_empty : t -> bool

include Interfaces.EQ with type t := t
include Interfaces.HASH with type t := t
include Interfaces.PRINT with type t := t

val hash_mod_alpha : t -> int

(** The index of a literal in the clause *)

val lits_seq : t -> (idx * Lit.t) Sequence.t

val pp : t CCFormat.printer

(** {2 Classification} *)

(** Some clauses are Horn, some are unit equations, some are unit,
    and the others are general *)

type kind =
  | Horn of horn_clause
  | General

val classify : t -> kind

val is_ground : t -> bool
val is_unit_ground : t -> bool

(** {2 Utils} *)

val of_slit_l :
  stmt:Statement.clause_t ->
  FOTerm.t SLiteral.t list ->
  t
(** Conversion from some clause in the given statement *)

val is_trivial : t -> bool
(** Is the clause trivial? *)

(** {2 Unif} *)

val variant :
  ?subst:Subst.t ->
  t Scoped.t ->
  t Scoped.t ->
  Subst.t Sequence.t

val equal_mod_alpha : t -> t -> bool

module Tbl_mod_alpha : CCHashtbl.S with type key = clause
