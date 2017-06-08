
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Classify Literals} *)

module T = Term

type shielded = [`Shielded | `Unshielded]
type sign = bool

type constraint_ =
  | C_arith (* arith negative equality, seen as constraint *)
  | C_ho (* F args != t *)
  | C_purify (* X != t, X of purifiable type *)

type class_ =
  | K_normal of sign (* any "normal" kind of literal *)
  | K_constr of constraint_ * shielded (* constraint *)

type t = class_ array

(* combine the "shielded" status *)
let (+++) a b = match a, b with
  | `Unshielded, _
  | _, `Unshielded -> `Unshielded
  | `Shielded, `Shielded -> `Shielded

let is_unshielded_constr = function
  | K_constr (_, `Unshielded) -> true
  | K_normal _ | K_constr _ -> false

let pp_shield out = function
  | `Shielded -> CCFormat.string out "shielded"
  | `Unshielded -> CCFormat.string out "unshielded"

let pp_constr out = function
  | C_arith -> CCFormat.string out "arith_constr"
  | C_ho -> CCFormat.string out "ho_constr"
  | C_purify -> CCFormat.string out "purify_constr"

let pp_class out = function
  | K_normal s -> Format.fprintf out "normal :sign %B" s
  | K_constr (c,s) -> Format.fprintf out "%a %a" pp_constr c pp_shield s

let pp out a =
  let pp_i out (i,cl) = Format.fprintf out "(%d: %a)" i pp_class cl in
  Format.fprintf out "(@[<hv>%a@])"
    (Util.pp_seq ~sep:" " pp_i) (Sequence.of_array_i a)

let classify (lits:Literals.t): t =
  let shield_status v =
    if Purify.is_shielded v lits then `Shielded else `Unshielded
  in
  lits |> Array.map
    (fun lit -> match lit with
       | Literal.Equation (t, u, false) ->
         let hd_t, args_t = T.as_app t in
         let hd_u, args_u = T.as_app u in
         begin match T.view hd_t, T.view hd_u with
           | T.Var v1, T.Var v2 when args_t <> [] && args_u <> [] ->
             K_constr (C_ho, shield_status v1 +++ shield_status v2)
           | T.Var v, _ when args_t <> [] ->
             (* HO unif constraint *)
             K_constr (C_ho, shield_status v)
           | _, T.Var v when args_u <> [] ->
             K_constr (C_ho, shield_status v)
           | T.Var v, _ when Type.is_fun (T.ty t) ->
             K_constr (C_purify, shield_status v)
           | _, T.Var v when Type.is_fun (T.ty u) ->
             K_constr (C_purify, shield_status v)
           | _ -> K_normal (Literal.sign lit)
         end
       | Literal.Prop (t, sign) ->
         let hd_t, args_t = T.as_app t in
         begin match T.view hd_t, args_t with
           | T.Var v, [] -> K_constr (C_purify, shield_status v)
           | T.Var v, _::_ -> K_constr (C_ho, shield_status v)
           | _ -> K_normal sign
         end
       | Literal.Int (Int_lit.Binary (Int_lit.Different, m1, m2)) ->
         let vars =
           Sequence.append (Monome.Seq.terms m1) (Monome.Seq.terms m2)
           |> Sequence.filter_map T.as_var
           |> Sequence.to_rev_list
         in
         begin match vars with
           | [] -> K_normal (Literal.sign lit) (* no vars *)
           | _::_ ->
             let st =
               List.fold_left (fun acc v -> acc +++ shield_status v) `Shielded vars
             in
             K_constr (C_arith, st)
         end
       | _ -> K_normal (Literal.sign lit))