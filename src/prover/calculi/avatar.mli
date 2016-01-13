
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Basic Splitting à la Avatar}

    We don't implement all the stuff from Avatar, in particular all clauses are
    active whether or not their trail is satisfied in the current model.
    Trails are only used to make splits easier {b currently}.

    Future work may include locking clauses whose trails are unsatisfied.

    Depends on the "meta" extension.
*)

type 'a printer = Format.formatter -> 'a -> unit

(** {2 Avatar: splitting+sat} *)

module type S = Avatar_intf.S

module Make(E : Env.S)(Sat : Sat_solver.S) : S
  with module E = E
   and module Solver = Sat

val key : (module S) CCMixtbl.injection

val get_env : (module Env.S) -> (module S)

val extension : Extensions.t
(** Extension that enables Avatar splitting and create a new SAT-solver. *)
