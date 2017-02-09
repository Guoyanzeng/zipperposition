
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Basics for Hornet Types} *)

open Libzipperposition
open Hornet_types

module T = FOTerm
module Fmt = CCFormat

let pp_lit out (t:lit): unit = match t with
  | Bool b -> Fmt.bool out b
  | Atom (t, true) -> T.pp out t
  | Atom (t, false) -> Fmt.fprintf out "@[@<1>¬@[%a@]@]" T.pp t
  | Eq (t,u,true) -> Fmt.fprintf out "@[%a@ = %a@]" T.pp t T.pp u
  | Eq (t,u,false) -> Fmt.fprintf out "@[%a@ @<1>≠ %a@]" T.pp t T.pp u

let pp_clause_lits out a =
  Fmt.fprintf out "@[%a@]" (Fmt.seq pp_lit) (IArray.to_seq a.c_lits)
let pp_clause out (a:clause) = Fmt.within "[" "]" pp_clause_lits out a

let pp_atom out = function
  | A_fresh i -> Fmt.fprintf out "fresh_%d" i
  | A_box_clause (c,i) -> Fmt.fprintf out "%a/%d" pp_clause_lits c i
  | A_select (c,i,id) ->
    Fmt.fprintf out "@[select@ :idx %d@ :id %d :clause %a@]" i id pp_clause c
  | A_ground lit -> pp_lit out lit

let pp_bool_lit =
  let pp_inner out l =
    if l.bl_sign
    then pp_atom out l.bl_atom
    else Fmt.fprintf out "¬%a" pp_atom l.bl_atom
  in
  Fmt.within "⟦" "⟧" pp_inner

let pp_bool_clause out l =
  Fmt.fprintf out "[@[<hv>%a@]]" (Util.pp_list ~sep:" ⊔ " pp_bool_lit) l

let pp_constraint out (c:c_constraint_): unit = match c with
  | C_dismatch d -> Dismatching_constr.pp out d

let pp_hclause out (c:horn_clause): unit =
  let pp_constr out = function
    | [] -> Fmt.silent out ()
    | l -> Fmt.fprintf out "| @[<hv>%a@]" (Fmt.list pp_constraint) l
  in
  Fmt.fprintf out "(@[%a@ @<1>← @[<hv>%a@]@,%a@])"
    pp_lit c.hc_head
    (Fmt.seq pp_lit) (IArray.to_seq c.hc_body)
    pp_constr c.hc_constr

let pp_proof out (p:proof) : unit = match p with
  | P_from_stmt st ->
    Fmt.fprintf out "(@[from_stmt@ %a@])" Statement.pp_clause st
  | P_instance (c, subst) ->
    Fmt.fprintf out "(@[<hv2>instance@ :clause %a@ :subst %a@])"
      pp_clause c Subst.pp subst
  | P_avatar_split c ->
    Fmt.fprintf out "(@[<hv2>avatar_split@ :from %a@])" pp_clause c
  | P_split c ->
    Fmt.fprintf out "(@[<hv2>split@ %a@])" pp_clause c
  | P_bool_tauto -> Fmt.string out "bool_tauto"
  | P_bool_res r ->
    Fmt.fprintf out "(@[<hv>bool_res@ :c1 %a@ :c2 %a@])"
      pp_bool_clause r.bool_res_c1
      pp_bool_clause r.bool_res_c2
  | P_hc_superposition sup ->
    Fmt.fprintf out "(@[<hv2>hc_sup@ :active %a@ :passive %a@ :subst %a@])"
      pp_hclause sup.hc_sup_active
      pp_hclause sup.hc_sup_passive
      Subst.pp sup.hc_sup_subst
  | P_hc_simplify c ->
    Fmt.fprintf out "(@[simplify@ %a@])" pp_hclause c

let equal_lit (a:lit) (b:lit): bool = match a, b with
  | Bool b1, Bool b2 -> b1=b2
  | Atom (t1,sign1), Atom (t2,sign2) -> T.equal t1 t2 && sign1=sign2
  | Eq (t1,u1,sign1), Eq (t2,u2,sign2) ->
    sign1=sign2 &&
    T.equal t1 t2 && T.equal u1 u2
  | Bool _, _
  | Atom _, _
  | Eq _, _
    -> false

let hash_lit : lit -> int = function
  | Bool b -> Hash.combine2 10 (Hash.bool b)
  | Atom (t,sign) -> Hash.combine3 20 (T.hash t) (Hash.bool sign)
  | Eq (t,u,sign) -> Hash.combine4 30 (T.hash t) (T.hash u) (Hash.bool sign)

let equal_bool_lit a b : bool =
  a.bl_sign = b.bl_sign
  &&
  begin match a.bl_atom, b.bl_atom with
    | A_fresh i, A_fresh j ->  i=j
    | A_box_clause (_,i1), A_box_clause (_,i2) -> i1=i2
    | A_ground l1, A_ground l2 -> equal_lit l1 l2
    | A_select (_,_,id1), A_select (_,_,id2) -> id1=id2
    | A_fresh _, _
    | A_box_clause _, _
    | A_ground _, _
    | A_select _, _
      -> false
  end

let hash_bool_lit a : int = match a.bl_atom with
  | A_fresh i -> Hash.combine3 10 (Hash.bool a.bl_sign) (Hash.int i)
  | A_box_clause (_,i) -> Hash.combine2 15 (Hash.int i)
  | A_select (_,_,i) ->
    Hash.combine3 20 (Hash.bool a.bl_sign) (Hash.int i)
  | A_ground lit -> Hash.combine2 50 (hash_lit lit)

let pp_stage out = function
  | Stage_init -> Fmt.string out "init"
  | Stage_presaturate -> Fmt.string out "presaturate"
  | Stage_start -> Fmt.string out "start"
  | Stage_exit -> Fmt.string out "exit"

let pp_event out (e:event): unit = match e with
  | E_add_component c -> Fmt.fprintf out "(@[add_component@ %a@])" pp_clause c
  | E_remove_component c -> Fmt.fprintf out "(@[remove_component@ %a@])" pp_clause c
  | E_select_lit (c,lit,cstr) ->
    Fmt.fprintf out "(@[select_lit@ %a@ :clause %a@ :constr (@[%a@])@])"
      pp_lit lit pp_clause c (Util.pp_list Dismatching_constr.pp) cstr
  | E_unselect_lit (c,lit) ->
    Fmt.fprintf out "(@[select_lit@ %a@ :clause %a@])"
      pp_lit lit pp_clause c
  | E_add_ground_lit lit ->
    Fmt.fprintf out "(@[add_ground_lit@ %a@])" pp_lit lit
  | E_remove_ground_lit lit ->
    Fmt.fprintf out "(@[remove_ground_lit@ %a@])" pp_lit lit
  | E_found_unsat p ->
    Fmt.fprintf out "(@[found_unsat@ :proof %a@])" pp_proof p
  | E_stage s -> Fmt.fprintf out "(@[stage %a@])" pp_stage s
