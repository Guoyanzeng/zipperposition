
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

(** {1 Basic context for literals, clauses...} *)

open Logtk

module T = FOTerm
module S = Substs
module Unif = Logtk.Unif
module TO = Theories.TotalOrder

type scope = Substs.scope

(** {2 Context for a Proof} *)
module type S = Ctx_intf.S

let prof_add_signature = Util.mk_profiler "ctx.add_signature"
let prof_declare_sym= Util.mk_profiler "ctx.declare"

module Make(X : sig
  val signature : Signature.t
  val ord : Ordering.t
  val select : Selection.t
end) = struct
  let _ord = ref X.ord
  let _select = ref X.select
  let _signature = ref X.signature
  let _complete = ref true
  let _ad_hoc = ref (Symbol.Set.singleton Symbol.Base.eq)

  let skolem = Skolem.create ~prefix:"zsk" Signature.empty
  let renaming = S.Renaming.create ()
  let ord () = !_ord
  let set_ord o = _ord := o
  let selection_fun () = !_select
  let set_selection_fun s = _select := s
  let signature () = !_signature
  let complete () = !_complete

  let on_new_symbol = Signal.create()
  let on_signature_update = Signal.create()

  let find_signature s = Signature.find !_signature s
  let find_signature_exn s = Signature.find_exn !_signature s

  let compare t1 t2 = Ordering.compare !_ord t1 t2

  let select lits = !_select lits

  let lost_completeness () =
    if !_complete then Util.debug 1 "completeness is lost";
    _complete := false

  let is_completeness_preserved = complete

  let add_signature signature =
    Util.enter_prof prof_add_signature;
    let _diff = Signature.diff signature !_signature in
    _signature := Signature.merge !_signature signature;
    Signal.send on_signature_update !_signature;
    Signature.iter _diff (fun s ty -> Signal.send on_new_symbol (s,ty));
    _ord := !_signature
      |> Signature.Seq.to_seq
      |> Sequence.map fst
      |> Ordering.add_seq !_ord;
    Util.exit_prof prof_add_signature;
    ()

  let _declare_symb symb ty =
    let is_new = not (Signature.mem !_signature symb) in
    _signature := Signature.declare !_signature symb ty;
    if is_new then (
      Signal.send on_signature_update !_signature;
      Signal.send on_new_symbol (symb,ty);
    )

  let declare symb ty =
    Util.enter_prof prof_declare_sym;
    _declare_symb symb ty;
    Util.exit_prof prof_declare_sym;
    ()

  let update_prec symbs =
    Util.debug 3 "update precedence...";
    _ord := Ordering.update_precedence !_ord
      (fun prec -> Precedence.add_seq prec symbs)

  let ad_hoc_symbols () = !_ad_hoc
  let add_ad_hoc_symbols seq =
    _ad_hoc := Sequence.fold (fun set s -> Symbol.Set.add s set) !_ad_hoc seq

  let renaming_clear () =
    S.Renaming.clear renaming;
    renaming

  module Lit = struct
    let _from = ref []
    let _to = ref []

    let from_hooks () = !_from
    let to_hooks () = !_to

    let add_to_hook h = _to := h :: !_to
    let add_from_hook h = _from := h :: !_from

    let of_form f = Literal.Conv.of_form ~hooks:!_from f
    let to_form f = Literal.Conv.to_form ~hooks:!_to f
  end

  module Theories = struct
    module STbl = Symbol.Tbl
    module PF = PFormula

    module AC = struct
      let tbl = STbl.create 3
      let proofs = STbl.create 3
      let on_add = Signal.create ()

      let axioms s =
        (* FIXME: need to recover type of [f]
        let x = T.mk_var 0 in
        let y = T.mk_var 1 in
        let z = T.mk_var 2 in
        let f x y = T.mk_node s [x; y] in
        let mk_eq x y = F.mk_eq x y in
        let mk_pform name f =
          let f = F.close_forall f in
          let name = Util.sprintf "%s_%a" name Symbol.pp s in
          let proof = Proof.mk_f_axiom f ~file:"/dev/ac" ~name in
          PF.create f proof
        in
        [ mk_pform "associative" (mk_eq (f (f x y) z) (f x (f y z)))
        ; mk_pform "commutative" (mk_eq (f x y) (f y x))
        ]
        *)
        []

      let add ?proof ~ty s =
        let proof = match proof with
        | Some p -> p
        | None -> (* new axioms *)
          List.map PF.proof (axioms s)
        in
        if not (STbl.mem tbl s)
        then begin
          let instance = Theories.AC.({ty; sym=s}) in
          STbl.replace tbl s instance;
          STbl.replace proofs s proof;
          Signal.send on_add instance
        end

      let is_ac s = STbl.mem tbl s

      let exists_ac () = STbl.length tbl > 0

      let find_proof s = STbl.find proofs s

      let symbols () =
        STbl.fold
          (fun s _ set -> Symbol.Set.add s set)
          tbl Symbol.Set.empty

      let symbols_of_terms seq =
        let module A = T.AC(struct
          let is_ac = is_ac
          let is_comm _ = false
        end) in
        A.symbols seq

      let symbols_of_forms f =
        Sequence.flatMap Formula.FO.Seq.terms f |> symbols_of_terms

      let proofs () =
        STbl.fold
          (fun _ proofs acc -> List.rev_append proofs acc)
          proofs []
    end

    module TotalOrder = struct
      module InstanceTbl = Hashtbl.Make(struct
        type t = TO.t
        let equal = TO.eq
        let hash = TO.hash
      end)

      let less_tbl = STbl.create 3
      let lesseq_tbl = STbl.create 3
      let proofs = InstanceTbl.create 3
      let on_add = Signal.create ()

      let is_less s = STbl.mem less_tbl s

      let is_lesseq s = STbl.mem lesseq_tbl s

      let find s =
        try
          STbl.find less_tbl s
        with Not_found ->
          STbl.find lesseq_tbl s

      let is_order_symbol s =
        STbl.mem less_tbl s || STbl.mem lesseq_tbl s

      let find_proof instance =
        InstanceTbl.find proofs instance

      let axioms ~less ~lesseq =
        (* FIXME: need to recover type of less's arguments
        let x = T.mk_var 0 in
        let y = T.mk_var 1 in
        let z = T.mk_var 2 in
        let mk_less x y = F.mk_atom (T.mk_node ~ty:Type.o less [x;y]) in
        let mk_lesseq x y = F.mk_atom (T.mk_node ~ty:Type.o lesseq [ x;y]) in
        let mk_eq x y = F.mk_eq x y in
        let mk_pform name f =
          let f = F.close_forall f in
          let name = Util.sprintf "%s_%a_%a" name Symbol.pp less Symbol.pp lesseq in
          let proof = Proof.mk_f_axiom f ~file:"/dev/order" ~name in
          PF.create f proof
        in
        [ mk_pform "total" (F.mk_or [mk_less x y; mk_eq x y; mk_less y x])
        ; mk_pform "irreflexive" (F.mk_not (mk_less x x))
        ; mk_pform "transitive" (F.mk_imply (F.mk_and [mk_less x y; mk_less y z]) (mk_less x z))
        ; mk_pform "nonstrict" (F.mk_equiv (mk_lesseq x y) (F.mk_or [mk_less x y; mk_eq x y]))
        ]
        *)
        []

      let add ?proof ~less ~lesseq ~ty =
        let proof = match proof with
        | Some p -> p
        | None ->
          List.map PF.proof (axioms ~less ~lesseq)
        in
        let instance =
          try Some (STbl.find lesseq_tbl lesseq)
          with Not_found ->
            if STbl.mem less_tbl less
              then raise (Invalid_argument "ordering instances overlap")
              else None
        in
        match instance with
        | None ->
          (* new instance *)
          let instance = Theories.TotalOrder.({ less; lesseq; ty; }) in
          STbl.add less_tbl less instance;
          STbl.add lesseq_tbl lesseq instance;
          InstanceTbl.add proofs instance proof;
          Signal.send on_add instance;
          instance, `New
        | Some instance ->
          if not (Unif.Ty.are_variant ty instance.TO.ty)
          then raise (Invalid_argument "incompatible types")
          else if not (Symbol.eq less instance.TO.less)
          then raise (Invalid_argument "incompatible symbol for lesseq")
          else instance, `Old

      let add_tstp () =
        try
          find Symbol.TPTP.Arith.less, `Old
        with Not_found ->
          let less = Symbol.TPTP.Arith.less in
          let lesseq = Symbol.TPTP.Arith.lesseq in
          (* add instance *)
          add ?proof:None
            ~ty:Type.(forall [var 0] (TPTP.o <== [var 0; var 0])) ~less ~lesseq

      let exists_order () =
        assert (STbl.length lesseq_tbl = STbl.length less_tbl);
        STbl.length less_tbl > 0
    end
  end

  (** Boolean Mapping *)
  module BoolLit = BBox.Make(struct end)

  (** Induction *)
  module Induction = struct
    type constructor = Symbol.t * Type.t
    (** constructor + its type *)

    type inductive_type = {
      pattern : Type.t;
      constructors : constructor list;
    }

    let _raise f fmt =
      let buf = Buffer.create 15 in
      Printf.kbprintf (fun buf -> f (Buffer.contents buf))
        buf fmt
    let _failwith fmt = _raise failwith fmt
    let _invalid_arg fmt = _raise invalid_arg fmt

    let _tbl_ty : inductive_type Symbol.Tbl.t = Symbol.Tbl.create 16

    let _extract_hd ty =
      match Type.view (snd (Type.open_fun ty)) with
      | Type.App (s, _) -> s
      | _ ->
          _invalid_arg "expected function type, got %a" Type.pp ty

    let declare_ty ty constructors =
      let name = _extract_hd ty in
      if constructors = []
        then invalid_arg "InductiveCst.declare_ty: no constructors provided";
      try
        Symbol.Tbl.find _tbl_ty name
      with Not_found ->
        let ity = { pattern=ty; constructors; } in
        Symbol.Tbl.add _tbl_ty name ity;
        ity

    let _seq_inductive_types yield =
      Symbol.Tbl.iter (fun _ ity -> yield ity) _tbl_ty

    let is_inductive_type ty =
      _seq_inductive_types
        |> Sequence.exists (fun ity -> Unif.Ty.matches ~pattern:ity.pattern ty)

    let _get_ity ty =
      let s = _extract_hd ty in
      try Symbol.Tbl.find _tbl_ty s
      with Not_found ->
        failwith (Util.sprintf "type %a is not inductive" Type.pp ty)

    type cst = FOTerm.t

    module IMap = Sequence.Map.Make(CCInt)

    type cover_set = {
      cases : T.t list; (* covering set itself *)
      sub_constants : T.Set.t;  (* skolem constants for recursive cases *)
    } (* TODO: recursive cases; base cases *)

    type cst_data = {
      cst : cst;
      ty : inductive_type;
      subst : Substs.t; (* matched against [ty.pattern] *)
      parent : cst option;
      mutable coversets : cover_set IMap.t;
        (* depth-> exhaustive decomposition of given depth  *)
    }

    (* cst -> cst_data *)
    let _tbl : cst_data T.Tbl.t = T.Tbl.create 16

    (* sub_constants -> cst * case in which the sub_constant occurs *)
    let _tbl_sub_cst : (cst * T.t) T.Tbl.t = T.Tbl.create 16

    let _blocked = ref []

    let is_sub_constant t =
      T.Tbl.mem _tbl_sub_cst t

    let is_blocked t =
      is_sub_constant t

    let declare ?parent t =
      if T.is_ground t
      then
        if T.Tbl.mem _tbl t then ()
        else try
          Util.debug 2 "declare new inductive constant %a" T.pp t;
          (* check that the type of [t] is inductive *)
          let ty = T.ty t in
          let name = _extract_hd ty in
          let ity = Symbol.Tbl.find _tbl_ty name in
          let subst = Unif.Ty.matching ~pattern:ity.pattern 1 ty 0 in
          let cst_data = { cst=t; ty=ity; subst; parent; coversets=IMap.empty } in
          T.Tbl.add _tbl t cst_data;
          ()
        with Unif.Fail | Not_found ->
          _invalid_arg "term %a doesn't have an inductive type" T.pp t
      else _invalid_arg "term %a is not ground, cannot be an inductive constant" T.pp t

    (* monad over "lazy" values *)
    module FunM = CCFun.Monad(struct type t = unit end)
    module FunT = CCList.Traverse(FunM)

    (* coverset of given depth for this type and constant *)
    let _make_coverset ~depth ity cst =
      (* list of cover term generators *)
      let rec make depth =
        (* leaves: fresh constants *)
        if depth=0 then [fun () ->
          let ty = ity.pattern in
          let name = Util.sprintf "#%a" Symbol.pp (_extract_hd ty) in
          let c = Skolem.fresh_sym_with ~ctx:skolem ~ty name in
          _declare_symb c ty;
          let t = T.const ~ty c in
          t, T.Set.singleton t
        ]
        (* inner nodes or base cases: constructors *)
        else CCList.flat_map
          (fun (f, ty_f) ->
            match Type.arity ty_f with
            | Type.NoArity ->
                _failwith "invalid constructor %a for inductive type %a"
                  Symbol.pp f Type.pp ity.pattern
            | Type.Arity (0, 0) ->
                if depth > 0
                then [fun () -> T.const ~ty:ty_f f, T.Set.empty]  (* only one answer : f *)
                else []
            | Type.Arity (0, n) ->
                let ty_args = Type.expected_args ty_f in
                CCList.(
                  make_list (depth-1) ty_args >>= fun mk_args ->
                  return (fun () ->
                    let args, set = mk_args () in
                    T.app (T.const f ~ty:ty_f) args, set)
                )
            | Type.Arity (m,_) ->
                _failwith
                  "inductive constructor %a requires %d type parameters, expected 0"
                  Symbol.pp f m
          ) ity.constructors
      (* given a list of types [l], yield all lists of cover terms
          that have types [l] *)
      and make_list depth l : (T.t list * T.Set.t) FunM.t list = match l with
        | [] -> [fun()->[],T.Set.empty]
        | ty :: tail ->
            let t_builders = if Unif.Ty.matches ~pattern:ity.pattern ty
              then make depth
              else [fun () ->
                (* not an inductive sub-case, just create a skolem symbol *)
                let name = Util.sprintf "#%a" Symbol.pp (_extract_hd ty) in
                let c = Skolem.fresh_sym_with ~ctx:skolem ~ty name in
                _declare_symb c ty;
                let t = T.const ~ty c in
                (* declare [t] as a new inductive constant if its type is inductive *)
                if is_inductive_type ty then declare ~parent:cst t;
                t, T.Set.empty
            ] in
            let tail_builders = make_list depth tail in
            CCList.(
              t_builders >>= fun mk_t ->
              tail_builders >>= fun mk_tail ->
              [FunM.(mk_t >>= fun (t,set) ->
                     mk_tail >>= fun (tail,set') ->
                     return (t::tail, T.Set.union set set'))] 
            ) 
      in
      assert (depth>0);
      let cases_and_subs = List.map (fun gen -> gen()) (make depth) in
      List.iter 
        (fun (t, set) ->
          T.Set.iter
            (fun sub_cst -> T.Tbl.replace _tbl_sub_cst sub_cst (cst, t))
            set;
        ) cases_and_subs;
      let cases, sub_constants = List.split cases_and_subs in
      let sub_constants = List.fold_left T.Set.union T.Set.empty sub_constants in
      {cases; sub_constants= sub_constants; }

    let inductive_cst_of_sub_cst t = T.Tbl.find _tbl_sub_cst t

    let cover_set ?(depth=1) t =
      try
        let cst = T.Tbl.find _tbl t in
        begin try
          (* is there already a cover set at this depth? *)
          IMap.find depth cst.coversets, `Old
        with Not_found ->
          (* create a new cover set *)
          let ity = _get_ity (T.ty t) in
          let coverset = _make_coverset ~depth ity t in
          (* save coverset *)
          cst.coversets <- IMap.add depth coverset cst.coversets;
          Util.debug 2 "new coverset for %a: %a" T.pp t (CCList.pp T.pp) coverset.cases;
          coverset, `New
        end
      with Not_found ->
        _failwith "term %a is not an inductive constant, no coverset" T.pp t

    let is_inductive cst = T.Tbl.mem _tbl cst

    let _seq_inductive_cst yield =
      T.Tbl.iter (fun t _ -> yield t) _tbl

    module Set = T.Set

    let parent t =
      let cst_data = T.Tbl.find _tbl t in
      cst_data.parent

    let rec depends_on a b = match parent a with
      | None -> false
      | Some a' -> T.eq a' b || depends_on a' b

    let parent_exn t = match parent t with
      | None -> failwith "no parent"
      | Some t' -> t'

    let is_max_among t set =
      Set.for_all (fun t' -> not (depends_on t' t)) set

    module Seq = struct
      let ty = _seq_inductive_types
      let cst = _seq_inductive_cst

      let constructors =
        _seq_inductive_types
        |> Sequence.flat_map (fun ity -> Sequence.of_list ity.constructors)
        |> Sequence.map fst
    end
  end
end
