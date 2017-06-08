
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Higher-Order Unification} *)

(** Use combinators for higher-order unification and reduction.
    We follow "Higher-order unification via combinators", Dougherty.
*)

type term = Term.t

type penalty = int
(** penalty on the search space *)

(** {2 Set of Combinators} *)

module Combinators : sig
  type rule = Rewrite.Term.rule * penalty
  (** A rule is a term rewrite rule, plus a penalty on the search space *)

  type rules = rule list

  type t
  (** Set of combinators *)

  val rules : t -> rules
  val name : t -> string
  val decls : t -> (ID.t * Type.t) list

  val conv_lambda : t -> Type.t HVar.t list -> term -> term
  (** Convert toplevel lambda into combinators.
      [conv_lambda vars t] converts [λvars. t] into combinators *)

  val ski : t
  (** basic set + predicate combinators *)

  val ski_if : t
  (** Same as {!ski} + an "if then else" combinator *)

  val skibc : t
  (** Schönfickel's combinators *)

  val skibc_if : t

  val default : t

  val by_name : string -> t

  val list_names : unit -> string list
end

val unif_step :
  Combinators.t Scoped.t ->
  (term * term) Scoped.t ->
  (Subst.t * penalty) list
(** [unif_step c (t,u)] returns a set of possible steps
    for unifying [t] and [u] using combinators [c] *)
