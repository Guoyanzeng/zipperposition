
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Clause context}

    A clause with a "hole" in it. Filling the whole with a term [t] is called
    "applying the context to [t]".

    The point is to relate different applications of the same context. *)

open Logtk

module T = FOTerm
module Subst = Substs
module Lits = Literals

type term = T.t
type subst = Substs.t

(** A context is represented as a regular array of literals, containing
    at least one specific variable [x], paired with this variable [x].
    Applying the context is a mere substitution *)
type t = {
  lits : Literals.t;
  var : T.var;
}
type ctx=t

let equal c1 c2 = HVar.equal c1.var c2.var && Lits.equal c1.lits c2.lits

let raw_lits t = t.lits

(* TODO: compare types of extruded variables;
   if same type, instantiate with some specific "diamond" of that type
   and check for alpha-equiv *)
let compare c1 c2 =
  CCOrd.(HVar.compare c1.var c2.var <?> (Lits.compare, c1.lits, c2.lits))

let make lits ~var =
  assert (Lits.Seq.terms lits
          |> Sequence.exists (T.var_occurs ~var)
         );
  {lits;var}

let extract lits t =
  if Lits.Seq.terms lits |> Sequence.exists (T.subterm ~sub:t)
  then
    (* create fresh var to replace [t] *)
    let i = Lits.Seq.terms lits
            |> Sequence.flat_map T.Seq.vars
            |> T.Seq.max_var
    in
    let var = HVar.make ~ty:(T.ty t) (i+1) in
    let var_t = T.var var in
    (* replace [t] with [var] *)
    let lits =
      Array.map
        (Literal.map (fun root_t -> T.replace root_t ~old:t ~by:var_t))
        lits
    in
    Some {lits;var}
  else None

let extract_exn lits t = match extract lits t with
  | None -> invalid_arg "ClauseContext.extract_exn"
  | Some c -> c

let _apply_subst subst (lits, sc) =
  let renaming = Subst.Renaming.create () in
  Array.map (fun lit -> Literal.apply_subst_no_simp ~renaming subst (lit, sc)) lits

let apply {lits;var} t =
  let var = (var : T.var :> InnerTerm.t HVar.t) in
  let subst = Subst.FO.bind Subst.empty (var, 0) (t, 1) in
  _apply_subst subst (lits, 0)

let apply_same_scope {lits;var} t =
  let var = (var : T.var :> InnerTerm.t HVar.t) in
  let subst = Subst.FO.bind Subst.empty (var, 0) (t, 0) in
  _apply_subst subst (lits, 0)

let _diamond = ID.make "◇"

let pp out c =
  let cst = T.const ~ty:(HVar.ty c.var) _diamond in
  let lits = apply_same_scope c cst in
  Format.fprintf out "[@[%a@]]" Lits.pp lits

module Set = CCSet.Make(struct
    type t = ctx
    let compare = compare
  end)
