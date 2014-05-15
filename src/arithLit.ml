
(*
Zipperposition: a functional superposition prover for prototyping
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

open Logtk

type term = FOTerm.t
type scope = Substs.scope

module T = FOTerm
module S = Substs
module F = Formula.FO
module P = Position
module M = Monome
module MF = Monome.Focus

(** {2 Type Decls} *)

type op =
  | Equal
  | Different
  | Less
  | Lesseq

type 'm divides = {
  num : Z.t;
  power : int;
  monome : 'm;
  sign : bool;
} (** [num^power divides monome] or not. *)

type t =
  | Binary of op * Z.t Monome.t * Z.t Monome.t
  | Divides of Z.t Monome.t divides
(** Arithmetic literal (on integers) *)

type lit = t

(** {2 Basics} *)

let eq lit1 lit2 = match lit1, lit2 with
  | Binary (op1, x1, y1), Binary (op2, x2, y2) ->
      op1 = op2 && M.eq x1 x2 && M.eq y1 y2
  | Divides d1, Divides d2 ->
      d1.sign = d2.sign && d1.power = d2.power &&
      Z.equal d1.num d2.num && M.eq d1.monome d2.monome
  | _, _ -> false

let eq_com lit1 lit2 = match lit1, lit2 with
  | Binary (op1, x1, y1), Binary (op2, x2, y2)
  when op1 = op2 && (op1 = Equal || op1 = Different) ->
      (M.eq x1 x2 && M.eq y1 y2) || (M.eq x1 y2 && M.eq x2 y1)
  | _ -> eq lit1 lit2

let cmp lit1 lit2 = match lit1, lit2 with
  | Binary (op1, x1, y1), Binary (op2, x2, y2) ->
      let c = compare op1 op2 in
      if c <> 0 then c
      else let c = M.compare x1 x2 in
      if c <> 0 then c else M.compare y1 y2
  | Divides d1, Divides d2 ->
      Util.lexicograph_combine
        [ compare d1.sign d2.sign
        ; compare d1.power d2.power
        ; Z.compare d1.num d2.num
        ; M.compare d1.monome d2.monome ]
  | Binary _,  Divides _ -> 1
  | Divides _, Binary _ -> -1

let hash = function
  | Binary (op, m1, m2) -> Hash.hash_int3 (Hashtbl.hash op) (M.hash m1) (M.hash m2)
  | Divides d ->
      Hash.hash_int3 (Z.hash d.num) (M.hash d.monome) d.power

let sign = function
  | Binary ((Equal | Lesseq | Less), _, _) -> true
  | Binary (Different, _, _) -> false
  | Divides d -> d.sign

let is_pos = sign
let is_neg l = not (is_pos l)

let _is_bin p = function
  | Binary (op, _, _) -> p op
  | Divides _ -> false

let is_eq = _is_bin ((=) Equal)
let is_neq = _is_bin ((=) Different)
let is_eqn = _is_bin (function Equal | Different -> true | _ -> false)
let is_less = _is_bin ((=) Less)
let is_lesseq = _is_bin ((=) Lesseq)
let is_ineq = _is_bin (function Less | Lesseq -> true | _ -> false)
let is_divides = function
  | Divides _ -> true
  | Binary _ -> false

let _normalize = Monome.Int.normalize

(* main constructor *)
let make op m1 m2 =
  let m1, m2 = _normalize m1, _normalize m2 in
  let m = M.difference m1 m2 in
  (* divide by gcd *)
  let m = M.Int.normalize_wrt_zero m in
  let m1, m2 = M.split m in
  Binary (op, m1, m2)

let mk_eq = make Equal
let mk_neq = make Different
let mk_less = make Less
let mk_lesseq = make Lesseq

let mk_divides ?(sign=true) n ~power m =
  let m = _normalize m in
  let nk = Z.pow n power in
  (* normalize coefficients so that they are within [0...nk-1] *)
  let norm_coeff c = Z.erem c nk in
  let m = M.map_num norm_coeff m in
  (* TODO: factorize m by some k; if k is n^p, then
      make the literal n^{power-p} | m/k *)
  Divides { sign; num=n; power; monome=m; }

let mk_not_divides = mk_divides ~sign:false

let negate = function
  | Binary (op, m1, m2) ->
      begin match op with
      | Equal -> Binary (Different, m1, m2)
      | Different -> Binary (Equal, m1, m2)
      | Less -> make Less m2 (M.succ m1) (* a<b --> b<=a ---> b<a+1 *)
      | Lesseq -> Binary (Less, m2, m1)
      end
  | Divides d -> Divides { d with sign=not d.sign; }

let pp buf = function
  | Binary (op, l, r) ->
    Printf.bprintf buf "%a %s %a"
      M.pp l
      (match op with Equal -> "=" | Different -> "≠"
        | Less -> "<" | Lesseq -> "≤")
      M.pp r
  | Divides d when d.sign ->
    let nk = Z.pow d.num d.power in
    Printf.bprintf buf "%s div %a" (Z.to_string nk) M.pp d.monome
  | Divides d ->
    let nk = Z.pow d.num d.power in
    Printf.bprintf buf "¬(%s div %a)" (Z.to_string nk) M.pp d.monome

let pp_tstp buf = function
  | Binary (Equal, l, r) ->
    Printf.bprintf buf "%a = %a" M.pp_tstp l M.pp_tstp r
  | Binary (Different, l, r) ->
    Printf.bprintf buf "%a != %a" M.pp_tstp l M.pp_tstp r
  | Binary (Less, l, r) ->
    Printf.bprintf buf "$less(%a, %a)" M.pp_tstp l M.pp_tstp r
  | Binary (Lesseq, l, r) ->
    Printf.bprintf buf "$lesseq(%a, %a)" M.pp_tstp l M.pp_tstp r
  | Divides d when d.sign ->
    let nk = Z.pow d.num d.power in
    Printf.bprintf buf "$remainder_e(%a, %s) = 0" M.pp_tstp d.monome (Z.to_string nk)
  | Divides d ->
    let nk = Z.pow d.num d.power in
    Printf.bprintf buf "$remainder_e(%a, %s) != 0" M.pp_tstp d.monome (Z.to_string nk)

let to_string = Util.on_buffer pp
let fmt fmt lit = Format.pp_print_string fmt (to_string lit)

(** {2 Operators} *)

let map f = function
  | Binary (op, m1, m2) -> Binary (op, M.map f m1, M.map f m2)
  | Divides d -> Divides { d with monome=M.map f d.monome; }

let fold f acc = function
  | Binary (_, m1, m2) ->
      let acc = Sequence.fold f acc (Monome.Seq.terms m1) in
      Sequence.fold f acc (Monome.Seq.terms m2)
  | Divides d ->
      Sequence.fold f acc (Monome.Seq.terms d.monome)

type 'a unif = subst:Substs.t -> 'a -> scope -> 'a -> scope -> Substs.t Sequence.t

(* match {x1,y1} in scope 1, with {x2,y2} with scope2 *)
let unif4 op ~subst x1 y1 sc1 x2 y2 sc2 k =
  op ~subst x1 sc1 x2 sc2
    (fun subst -> op ~subst y1 sc1 y2 sc2 k);
  op ~subst y1 sc1 x2 sc2
    (fun subst -> op ~subst x1 sc1 y2 sc2 k);
  ()

let generic_unif m_unif ~subst lit1 sc1 lit2 sc2 k = match lit1, lit2 with
  | Binary (((Equal | Different) as op1), x1, y1),
    Binary (((Equal | Different) as op2), x2, y2) when op1 = op2 ->
    (* try both ways *)
    unif4 m_unif ~subst x1 y1 sc1 x2 y2 sc2 k
  | Binary (op1, x1, y1), Binary (op2, x2, y2) ->
    if op1 = op2
      then m_unif ~subst x1 sc1 x2 sc2
        (fun subst -> m_unif ~subst y1 sc1 y2 sc2 k)
  | Divides d1, Divides d2 ->
    if Z.equal d1.num d2.num && d1.power = d2.power && d1.sign = d2.sign
      then m_unif ~subst d1.monome sc1 d2.monome sc2 k
  | Binary _, Divides _
  | Divides _, Binary _ -> ()

let unify ?(subst=Substs.empty) lit1 sc1 lit2 sc2 =
  generic_unif (fun ~subst -> M.unify ~subst) ~subst lit1 sc1 lit2 sc2

let matching ?(subst=Substs.empty) lit1 sc1 lit2 sc2 =
  generic_unif (fun ~subst -> M.matching ~subst) ~subst lit1 sc1 lit2 sc2

let variant ?(subst=Substs.empty) lit1 sc1 lit2 sc2 =
  generic_unif (fun ~subst -> M.variant ~subst) ~subst lit1 sc1 lit2 sc2

(* FIXME: how can we manage for
    a < 10 to subsumes  2.a < 21 ?
    this requires scaling before matching... Use MF.unify_mm then scaling?
*)
let subsumes ?(subst=Substs.empty) lit1 sc1 lit2 sc2 k =
  match lit1, lit2 with
  | Binary (Less, l1, r1), Binary (Less, l2, r2) ->
      (* if subst(r1 - l1) = r2-l2 - k where k>=0, then l1<r1 => l2+k<r2 => l2<r2
          so l1<r1 subsumes l2<r2. *)
      let m1 = M.difference r1 l1 in
      let m2 = M.difference r2 l2 in
      M.matching ~subst (M.remove_const m1) sc1 (M.remove_const m2) sc2
        (fun subst ->
          let renaming = Substs.Renaming.create () in
          let m = M.difference
            (M.apply_subst ~renaming subst m1 sc1)
            (M.apply_subst ~renaming subst m2 sc2) in
          assert (M.is_const m);
          (* now, if [m <= 0], then subst(r1-l1) always dominates r2-l2
              and subst is subsuming *)
          if M.sign m <= 0 then k subst)
  | _ ->
    generic_unif (fun ~subst -> M.matching ~subst) ~subst lit1 sc1 lit2 sc2 k

let are_variant lit1 lit2 =
  not (Sequence.is_empty (variant lit1 0 lit2 1))

let apply_subst ~renaming subst lit scope = match lit with
  | Binary (op, m1, m2) ->
    make op
      (M.apply_subst ~renaming subst m1 scope)
      (M.apply_subst ~renaming subst m2 scope)
  | Divides d ->
    mk_divides ~sign:d.sign d.num ~power:d.power
      (M.apply_subst ~renaming subst d.monome scope)

let is_trivial = function
  | Divides d when d.sign && Z.equal d.num Z.one -> true  (* 1 | x tauto *)
  | Divides d when d.sign ->
      M.is_const d.monome && Z.sign (Z.rem (M.const d.monome) d.num) = 0
  | Divides d ->
      M.is_const d.monome && Z.sign (Z.rem (M.const d.monome) d.num) <> 0
  | Binary (Equal, m1, m2) -> M.eq m1 m2
  | Binary (Less, m1, m2) -> M.dominates ~strict:true m2 m1
  | Binary (Lesseq, m1, m2) -> M.dominates ~strict:false m2 m1
  | Binary (Different, m1, m2) ->
      let m = M.difference m1 m2 in
      (* gcd of all the coefficients *)
      let gcd = M.coeffs m
        |> List.fold_left (fun c1 (c2,_) -> Z.gcd c1 c2) Z.one in
      (* trivial if: either it's a!=0, with a a constant, or if
        the GCD of all coefficients does not divide the constant
        (unsolvable diophantine equation) *)
      (M.is_const m && Z.sign (M.const m) <> 0)
      || (Z.sign (Z.rem (M.const m) gcd) <> 0)

let is_absurd = function
  | Binary (Equal, m1, m2) ->
      let m = M.difference m1 m2 in
      let gcd = M.coeffs m
        |> List.fold_left (fun c1 (c2,_) -> Z.gcd c1 c2) Z.one in
      (* absurd if: either it's a=0, with a a constant, or if
        the GCD of all coefficients does not divide the constant
        (unsolvable diophantine equation) *)
      (M.is_const m && M.sign m <> 0)
      || (Z.sign (Z.rem (M.const m) gcd) <> 0)
  | Binary (Different, m1, m2) -> M.eq m1 m2
  | Binary (Less, m1, m2) ->
      let m = M.difference m1 m2 in
      M.is_const m && M.sign m >= 0
  | Binary (Lesseq, m1, m2) ->
      let m = M.difference m1 m2 in
      M.is_const m && M.sign m > 0
  | Divides d when not (d.sign) && Z.equal d.num Z.one ->
      true  (* 1 not| x  is absurd *)
  | Divides d when d.sign ->
      (* n^k should divide a non-zero constant *)
      M.is_const d.monome && Z.sign (Z.rem (M.const d.monome) d.num) <> 0
  | Divides d ->
      (* n^k doesn't divide 0 is absurd *)
      M.is_const d.monome && Z.sign (Z.rem (M.const d.monome) d.num) = 0

let fold_terms ?(pos=P.stop) ?(vars=false) ~which ~ord ~subterms lit acc f =
  (* function to call at terms *)
  let at_term ~pos acc t =
    if subterms
      then T.all_positions ~vars ~pos t acc f
      else f acc t pos
  and fold_monome = match which with
    | `All -> M.fold
    | `Max -> M.fold_max ~ord
  in
  match lit with
  | Binary (op, m1, m2) ->
      let acc = fold_monome
        (fun acc i _ t -> at_term ~pos:P.(append pos (left (arg i stop))) acc t)
        acc m1
      in
      fold_monome
        (fun acc i _ t -> at_term ~pos:P.(append pos (right (arg i stop))) acc t)
        acc m2
  | Divides d ->
      fold_monome
        (fun acc i _ t -> at_term ~pos:P.(append pos (arg i stop)) acc t)
        acc d.monome

let max_terms ~ord = function
  | Binary (_, m1, m2) ->
      let l = M.terms m1 @ M.terms m2 in
      Multiset.max_l (Ordering.compare ord) l
  | Divides d ->
      Multiset.max_l (Ordering.compare ord) (M.terms d.monome)

let to_form = function
  | Binary (op, m1, m2) ->
    let t1 = M.Int.to_term m1 in
    let t2 = M.Int.to_term m2 in
    begin match op with
      | Equal -> F.Base.eq t1 t2
      | Different -> F.Base.neq t1 t2
      | Less ->
        let sym = Symbol.TPTP.Arith.less in
        let ty = Signature.find_exn Signature.TPTP.Arith.base sym in
        let cst = T.const ~ty sym in
        F.Base.atom (T.app_full cst [Type.TPTP.int] [t1; t2])
      | Lesseq ->
        let sym = Symbol.TPTP.Arith.lesseq in
        let ty = Signature.find_exn Signature.TPTP.Arith.base sym in
        let cst = T.const ~ty sym in
        F.Base.atom (T.app_full cst [Type.TPTP.int] [t1; t2])
    end
  | Divides d ->
    let nk = Z.pow d.num d.power in
    let t = M.Int.to_term d.monome in
    let sym = Symbol.TPTP.Arith.remainder_e in
    let ty = Signature.find_exn Signature.TPTP.Arith.base sym in
    let cst = T.const ~ty sym in
    (* $remainder_e(t, nk) = 0 *)
    let f = F.Base.eq
      (T.const ~ty:Type.TPTP.int (Symbol.of_int 0))
      (T.app cst [t; T.const ~ty:Type.TPTP.int (Symbol.mk_int nk)])
    in
    if d.sign then f else F.Base.not_ f

(** {2 Iterators} *)

module Seq = struct
  let terms lit k = match lit with
    | Binary (_, m1, m2) -> M.Seq.terms m1 k; M.Seq.terms m2 k
    | Divides d -> M.Seq.terms d.monome k

  let vars lit = terms lit |> Sequence.flatMap T.Seq.vars
end

(** {2 Focus on a Term} *)

module Focus = struct
  (** focus on a term in one of the two monomes *)
  type t =
    | Left of op * Z.t Monome.Focus.t * Z.t Monome.t
    | Right of op * Z.t Monome.t * Z.t Monome.Focus.t
    | Div of Z.t Monome.Focus.t divides

  let mk_left op mf m = Left (op, mf, m)
  let mk_right op m mf = Right (op, m, mf)
  let mk_div ?(sign=true) num ~power m =
    Div {power;num;sign;monome=m;}

  let get lit pos =
    match lit, pos with
    | Binary (op, m1, m2), P.Left (P.Arg (i, _)) ->
        Some (Left (op, M.Focus.get m1 i, m2))
    | Binary (op, m1, m2), P.Right (P.Arg (i, _)) ->
        Some (Right (op, m1, M.Focus.get m2 i))
    | Divides d, P.Arg (i, _) ->
        let d' = {
          sign=d.sign; power=d.power; num=d.num;
          monome=M.Focus.get d.monome i;
        } in
        Some (Div d')
    | _ -> None

  let get_exn lit pos = match get lit pos with
    | None ->
      invalid_arg
        (Util.sprintf "wrong position %a for focused arith lit %a"
          P.pp pos pp lit)
    | Some x -> x

  let focus_term lit t =
    match lit with
    | Binary (op, m1, m2) ->
        begin match M.Focus.focus_term m1 t with
        | Some mf1 ->
            assert (not (M.mem m2 t));
            Some (Left (op, mf1, m2))
        | None ->
            match M.Focus.focus_term m2 t with
            | None -> None
            | Some mf2 -> Some (Right (op, m1, mf2))
        end
    | Divides d ->
        begin match M.Focus.focus_term d.monome t with
        | None -> None
        | Some mf ->
            Some (Div {d with monome=mf; })
        end

  let focus_term_exn lit t = match focus_term lit t with
    | None -> failwith "ALF.focus_term_exn"
    | Some lit' -> lit'

  let replace a by = match a with
    | Left (op, mf, m) -> make op (M.sum (MF.rest mf) by) m
    | Right (op, m, mf) -> make op m (M.sum (MF.rest mf) by)
    | Div d -> mk_divides
      ~sign:d.sign d.num ~power:d.power (M.sum (MF.rest d.monome) by)

  let focused_monome = function
    | Left (_, mf, _)
    | Right (_, _, mf) -> mf
    | Div d -> d.monome

  let opposite_monome = function
    | Left (_, _, m)
    | Right (_, m, _) -> Some m
    | Div _ -> None

  let opposite_monome_exn l =
    match opposite_monome l with
    | None -> invalid_arg "ALF.opposite_monome_exn"
    | Some m -> m

  let term lit = MF.term (focused_monome lit)

  let fold_terms ?(pos=P.stop) lit acc f =
    match lit with
    | Binary (op, m1, m2) ->
      let acc = MF.fold_m ~pos:P.(append pos (left stop)) m1 acc
        (fun acc mf pos -> f acc (Left (op, mf, m2)) pos)
      in
      let acc = MF.fold_m ~pos:P.(append pos (right stop)) m2 acc
        (fun acc mf pos -> f acc (Right (op, m1, mf)) pos)
      in acc
    | Divides d ->
      MF.fold_m ~pos d.monome acc
        (fun acc mf pos -> f acc (Div {d with monome=mf}) pos)

  (* is the focused term maximal in the arithmetic literal? *)
  let is_max ~ord = function
    | Left (_, mf, m)
    | Right (_, m, mf) ->
        let t = MF.term mf in
        let terms = Sequence.append (M.Seq.terms m) (MF.rest mf |> M.Seq.terms) in
        Sequence.for_all
          (fun t' -> Ordering.compare ord t t' <> Comparison.Lt)
          terms
    | Div d ->
        let t = MF.term d.monome in
        Sequence.for_all
          (fun t' -> Ordering.compare ord t t' <> Comparison.Lt)
          (MF.rest d.monome |> M.Seq.terms)

  (* is the focused term maximal in the arithmetic literal? *)
  let is_strictly_max ~ord = function
    | Left (_, mf, m)
    | Right (_, m, mf) ->
        let t = MF.term mf in
        let terms = Sequence.append (M.Seq.terms m) (MF.rest mf |> M.Seq.terms) in
        Sequence.for_all
          (fun t' -> Ordering.compare ord t t' = Comparison.Gt)
          terms
    | Div d ->
        let t = MF.term d.monome in
        Sequence.for_all
          (fun t' -> Ordering.compare ord t t' = Comparison.Gt)
          (MF.rest d.monome |> M.Seq.terms)

  let map_lit ~f_m ~f_mf lit = match lit with
    | Left (op, mf, m) ->
        Left (op, f_mf mf, f_m m)
    | Right (op, m, mf) ->
        Right (op, f_m m, f_mf mf)
    | Div d ->
        Div { d with monome=f_mf d.monome; }

  let product lit z =
    map_lit
      ~f_mf:(fun mf -> MF.product mf z)
      ~f_m:(fun m -> M.product m z)
      lit

  let apply_subst ~renaming subst lit scope =
    map_lit
      ~f_mf:(fun mf -> MF.apply_subst ~renaming subst mf scope)
      ~f_m:(fun m -> M.apply_subst ~renaming subst m scope)
      lit

  let apply_subst_no_renaming subst lit scope =
    map_lit
      ~f_mf:(fun mf -> MF.apply_subst_no_renaming subst mf scope)
      ~f_m:(fun m -> M.apply_subst_no_renaming subst m scope)
      lit

  let unify ?(subst=Substs.empty) lit1 sc1 lit2 sc2 k =
    let _set_mf lit mf = match lit with
    | Left (op, _, m) -> Left (op, mf, m)
    | Right (op, m, _) -> Right (op, m, mf)
    | Div d ->
        Div { d with monome=mf; }
    in
    MF.unify_ff ~subst (focused_monome lit1) sc1 (focused_monome lit2) sc2
      (fun (mf1, mf2, subst) ->
        k (_set_mf lit1 mf1, _set_mf lit2 mf2, subst))

  (* scale focused literals to have the same coefficient *)
  let scale l1 l2 =
    let z1 = MF.coeff (focused_monome l1)
    and z2 = MF.coeff (focused_monome l2) in
    let gcd = Z.gcd z1 z2 in
    product l1 (Z.divexact z2 gcd), product l2 (Z.divexact z1 gcd)

  let scale_power lit power = match lit with
    | Div d ->
        if d.power > power then invalid_arg "scale_power: cannot scale down";
        (* multiply monome by d.num^(power-d.power) *)
        let diff = power - d.power in
        if diff = 0
          then lit
          else
            let monome = MF.product d.monome Z.(pow d.num diff) in
            Div { d with monome; power;}
    | Left _
    | Right _ -> invalid_arg "scale_power: not a divisibility lit"

  let op = function
    | Left (op, _, _)
    | Right (op, _, _) -> `Binary op
    | Div _ -> `Divides

  let unfocus = function
    | Left (op, m1_f, m2) -> Binary (op, MF.to_monome m1_f, m2)
    | Right (op, m1, m2_f) -> Binary (op, m1, MF.to_monome m2_f)
    | Div d ->
        let d' = {
          num=d.num; power=d.power; sign=d.sign;
          monome=MF.to_monome d.monome;
        } in
        Divides d'

  let pp buf lit =
    let op2str = function
      | Equal -> "="
      | Different -> "≠"
      | Less -> "<"
      | Lesseq -> "≤"
    in
    match lit with
    | Left (op, mf, m) ->
        Printf.bprintf buf "%a %s %a" MF.pp mf (op2str op) M.pp m
    | Right (op, m, mf) ->
        Printf.bprintf buf "%a %s %a" M.pp m (op2str op) MF.pp mf
    | Div d when d.sign ->
      let nk = Z.pow d.num d.power in
      Printf.bprintf buf "%s div %a" (Z.to_string nk) MF.pp d.monome
    | Div d ->
      let nk = Z.pow d.num d.power in
      Printf.bprintf buf "¬(%s div %a)" (Z.to_string nk) MF.pp d.monome

  let to_string = Util.on_buffer pp
  let fmt fmt lit = Format.pp_print_string fmt (to_string lit)
end

module Util = struct
  module ZTbl = Hashtbl.Make(Z)

  type divisor = {
    prime : Z.t;
    power : int;
  }

  let two = Z.of_int 2

  (* table from numbers to some of their divisor (if any) *)
  let _table = lazy (
    let t = ZTbl.create 256 in
    ZTbl.add t two None;
    t)

  let _divisors n = ZTbl.find (Lazy.force _table) n

  let _add_prime n =
    ZTbl.replace (Lazy.force _table) n None

  (* add to the table the fact that [d] is a divisor of [n] *)
  let _add_divisor n d =
    assert (not (ZTbl.mem (Lazy.force _table) n));
    ZTbl.add (Lazy.force _table) n (Some d)

  (* primality test, modifies _table *)
  let _is_prime n0 =
    let n = ref two in
    let bound = Z.succ (Z.sqrt n0) in
    let is_prime = ref true in
    while !is_prime && Z.leq !n bound do
      if Z.sign (Z.rem n0 !n) = 0
      then begin
        is_prime := false;
        _add_divisor n0 !n;
      end;
      n := Z.succ !n;
    done;
    if !is_prime then _add_prime n0;
    !is_prime

  let is_prime n =
    try
      begin match _divisors n with
      | None -> true
      | Some _ -> false
      end
    with Not_found ->
      match Z.probab_prime n 7 with
      | 0 -> false
      | 2 -> (_add_prime n; true)
      | 1 ->
          _is_prime n
      | _ -> assert false

  let rec _merge l1 l2 = match l1, l2 with
    | [], _ -> l2
    | _, [] -> l1
    | p1::l1', p2::l2' ->
        match Z.compare p1.prime p2.prime with
        | 0 ->
            {prime=p1.prime; power=p1.power+p2.power} :: _merge l1' l2'
        | n when n < 0 ->
            p1 :: _merge l1' l2
        | _ -> p2 :: _merge l1 l2'

  let rec _decompose n =
    try
      begin match _divisors n with
      | None -> [{prime=n; power=1;}]
      | Some q1 ->
          let q2 = Z.divexact n q1 in
          _merge (_decompose q1) (_decompose q2)
      end
    with Not_found ->
      ignore (_is_prime n);
      _decompose n

  let prime_decomposition n =
    if is_prime n
    then [{prime=n; power=1;}]
    else _decompose n

  let primes_leq n0 k =
    let n = ref two in
    while Z.leq !n n0 do
      if is_prime !n then k !n
    done
end
