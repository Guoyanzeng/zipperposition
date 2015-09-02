
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

(** {1 Meta Prover for zipperposition} *)

open Logtk

type 'a or_error = [`Ok of 'a | `Error of string]

let prof_scan_clause = Util.mk_profiler "meta.scan_clause"
let prof_scan_formula = Util.mk_profiler "meta.scan_formula"

module T = HOTerm
module F = Formula.FO
module PF = PFormula
module M = Logtk_meta
module Lit = Literal
module Lits = Literals

(** {2 Implementation} *)

let section = Util.Section.make ~parent:Const.section "meta"

module LitMap = HOTerm.Map

type lemma = CompactClause.t * Proof.t (** Lemma *)
type axiom = string * Type.t list * HOTerm.t
type theory = string * Type.t list * HOTerm.t
type rewrite = (FOTerm.t * FOTerm.t) list (** Rewrite system *)
type pre_rewrite = HORewriting.t

module Result = struct
  type t = {
    lemmas : lemma list;
    theories : theory list;
    axioms : axiom list;
    rewrite : rewrite list; (** list of rewrite systems *)
    pre_rewrite : pre_rewrite list;
  }

  let empty = {lemmas=[]; theories=[]; axioms=[]; rewrite=[]; pre_rewrite=[]}
  let is_empty r =
    let aux = function [] -> true | _ -> false in
    aux r.lemmas
    && aux r.theories
    && aux r.axioms
    && aux r.rewrite
    && aux r.pre_rewrite

  let lemmas t = t.lemmas
  let theories t = t.theories
  let axioms t = t.axioms
  let rewrite t = t.rewrite
  let pre_rewrite t = t.pre_rewrite

  let add_lemmas l t = {t with lemmas=l@t.lemmas}
  let add_theories l t = {t with theories=l@t.theories}
  let add_axioms l t = {t with axioms=l@t.axioms}
  let add_rewrite l t = {t with rewrite=l@t.rewrite}
  let add_pre_rewrite l t = {t with pre_rewrite=l@t.pre_rewrite}

  (** Merge [r] into [into] *)
  let merge_into r ~into = into
    |> add_lemmas r.lemmas
    |> add_theories r.theories
    |> add_axioms r.axioms
    |> add_rewrite r.rewrite
    |> add_pre_rewrite r.pre_rewrite

  let pp_theory_axiom out (name, _, t) =
    Format.fprintf out "%s %a" name T.fmt t

  let pp_rewrite_system out l =
    Format.fprintf out "@[<hov2>rewrite system@ %a@]"
      (CCList.print
         (fun out (a,b) -> Format.fprintf out "%a --> %a" FOTerm.fmt a FOTerm.fmt b))
      l

  let pp_pre_rewrite_system out l = HORewriting.fmt out l

  let print out r =
    Format.fprintf out "@[<hv2>results{@ ";
    if r.axioms <> []
    then Format.fprintf out "@[<hv2>axioms:@,%a@]@,"
      (CCList.print pp_theory_axiom) r.axioms;
    if r.theories <> []
    then Format.fprintf out "@[<hv2>theories:@ %a@]@,"
      (CCList.print pp_theory_axiom) r.theories;
    if r.lemmas <> []
    then Format.fprintf out "@[<hv2>lemmas:@ %a@]@,"
      (CCList.print (fun fmt (c,_) -> CompactClause.fmt fmt c)) r.lemmas;
    if r.rewrite <> []
    then Format.fprintf out "@[<hv2>rewrite systems:@ %a@]@,"
      (CCList.print pp_rewrite_system) r.rewrite;
    if r.pre_rewrite <> []
    then Format.fprintf out "@[<hv2>pre-rewrite systems:@ %a@]@,"
      (CCList.print pp_pre_rewrite_system) r.pre_rewrite;
    Format.fprintf out "@]}";
    ()
end

(** {2 Induction} *)

module Induction = struct
  type ty = {
    ty : Type.t;
    cstors : (Symbol.t * Type.t) list;
  }

  let make ty cstors = {ty; cstors; }

  let print out ity =
    let pp_cstor out (s, ty) =
      Format.fprintf out "@[%a:@,%a@]" Symbol.fmt s Type.fmt ty
    in
    Format.fprintf out "@[<hov2>ity{ty:@,%a,@ cstors:@,%a}@]"
      Type.fmt ity.ty (CCList.print pp_cstor) ity.cstors

  let const_cstor = Type.const (Symbol.of_string "inductive_constructor")

  (* assert [τ] is inductive using
     [inductive {ty=@τ, cstors=[cstor @ty1 c1, cstor @ty2 c2]}] *)
  let sym_inductive = Symbol.of_string "inductive"
  let ty_sym_inductive = Type.(forall [var 0] (
      M.Reasoner.property_ty <=.
      record ~rest:None [
        "ty", var 0;
        "cstors", multiset const_cstor
      ]
  ))

  (* build a constructor with a term [cstor(sym)] *)
  let sym_cstor = Symbol.of_string "cstor"
  let ty_sym_cstor = Type.(forall [var 0] (const_cstor <== [var 0]))

  let signature =
    Signature.of_list
      [ sym_inductive, ty_sym_inductive
      ; sym_cstor, ty_sym_cstor
      ]

  let pred_inductive = T.const ~ty:ty_sym_inductive sym_inductive
  let pred_cstor = T.const ~ty:ty_sym_cstor sym_cstor

  let t : ty M.Plugin.t = object
    method signature = signature
    method owns t = match T.view t with
      | T.At (hd, _) -> T.eq hd pred_inductive
      | _ -> false
    method clauses = []
    method to_fact ity =
      (* encode constructors *)
      let arg = T.record ~rest:None
        [ "ty", T.tylift ity.ty
        ; "cstors", T.multiset ~ty:const_cstor
            (List.map
              (fun (s, ty_s) ->
                (* term "cstor(ty_s, s)", roughly *)
                T.at_full pred_cstor ~tyargs:[ty_s] [T.const ~ty:ty_s s]
              ) ity.cstors
            )
        ]
      in
      T.at_full pred_inductive ~tyargs:[ity.ty] [arg]
    method of_fact t =
      None (* TODO: real implementation *)
  end
end

(** {2 Interface to the Meta-prover} *)

type t = {
  mutable prover : M.Prover.t;    (* real meta-prover *)
  mutable sources : Proof.t LitMap.t;     (** for reconstructing proofs *)
  mutable results : Result.t;
  mutable new_results : Result.t;  (* recent results *)
  on_theory : theory Signal.t;
  on_lemma : lemma Signal.t;
  on_axiom : axiom Signal.t;
  on_rewrite : rewrite Signal.t;
  on_pre_rewrite : pre_rewrite Signal.t;
}

let mk_prover_ =
  let p = M.Prover.empty in
  M.Prover.add_signature p Induction.t#signature

let create () = {
  prover = mk_prover_;
  sources = LitMap.empty;
  results = Result.empty;
  new_results = Result.empty;
  on_theory = Signal.create ();
  on_lemma = Signal.create ();
  on_axiom = Signal.create ();
  on_rewrite = Signal.create ();
  on_pre_rewrite = Signal.create ();
}

let results t = t.results

let pop_new_results t =
  let r = t.new_results in
  t.new_results <- Result.empty;
  r

let reasoner p = M.Prover.reasoner p.prover

let theories p = Result.theories p.results |> Sequence.of_list

let prover p = p.prover

let on_theory t = t.on_theory
let on_lemma t = t.on_lemma
let on_axiom t = t.on_axiom
let on_rewrite t = t.on_rewrite
let on_pre_rewrite t = t.on_pre_rewrite

let proof_of_explanation p exp =
  M.Reasoner.Proof.facts exp
  |> Sequence.filter_map
    (fun fact -> try Some (LitMap.find fact p.sources) with Not_found -> None)
  |> Sequence.to_rev_list

(* conversion back from meta-prover clauses *)
let clause_of_foclause_ l =
  let module F = Formula.FO in
  List.map
    (function
      | M.Encoding.Eq (a, b, sign) -> F.Base.mk_eq sign a b
      | M.Encoding.Prop (a, sign) -> F.Base.mk_atom sign a
      | M.Encoding.Bool true -> F.Base.true_
      | M.Encoding.Bool false -> F.Base.false_
    ) l

(* print content of the reasoner *)
let print_rules out r =
  Sequence.pp_seq M.Reasoner.Clause.fmt out (M.Reasoner.Seq.to_seq r)

(** {2 Interface to {!Env} *)

let key = Mixtbl.access ()

let get_global, clear_global =
  let global_ = ref None in
  (fun () -> match !global_ with
    | Some p -> p
    | None ->
      let p = create () in
      global_ := Some p;
      p
  ), (fun () -> global_ := None)

(** {2 CLI Options} *)

let theory_files = ref []
let flag_print_rules = ref false
let flag_print_signature = ref false
let flag_print_rules_exit = ref false

let add_theory f = theory_files := f :: !theory_files

(* add options *)
let () = Params.add_opts
  [ "-theory", Arg.String add_theory, " use given theory file for meta-prover"
  ; "-meta-rules", Arg.Set flag_print_rules, " print all rules of meta-prover"
  ; "-meta-summary", Arg.Set flag_print_rules_exit, " print all rules before exit"
  ; "-meta-sig", Arg.Set flag_print_signature, " print meta signature"
  ]

module type S = sig
  module E : Env.S
  module C : module type of E.C

  val parse_theory_file : t -> string -> Result.t or_error
  (** Update prover with the content of this file, returns the new results
      or an error *)

  val parse_theory_files : t -> string list -> Result.t or_error
  (** Parse several files *)

  val scan_formula : t -> PFormula.t -> Result.t
  (** Scan a formula for patterns, and save it *)

  val scan_clause : t -> C.t -> Result.t
  (** Scan a clause for axiom patterns, and save it *)

  val declare_inductive : t -> E.Ctx.Induction.inductive_type -> Result.t
  (** Declare the given inductive type *)

  (** {2 Inference System} *)

  val setup : unit -> unit
  (** [setup ()] registers some inference rules to [E]
      and adds a meta-prover  *)
end

(* TODO: handle ground convergent systems in Meta Prover, e.g. using
    a specific file... *)

module Make(E : Env.S) : S with module E = E = struct
  module E = E
  module C = E.C

  (* adds [consequences] to [p] *)
  let add_consequences p consequences =
    let facts = Sequence.map fst consequences in
    (* filter theories, axioms, lemmas... *)
    let theories =
      Sequence.filter_map M.Plugin.theory#of_fact facts
      |> Sequence.to_list
    and lemmas =
      Sequence.filter_map
        (fun (fact, explanation) ->
          CCOpt.(
            M.Plugin.lemma#of_fact fact
            >|= clause_of_foclause_
            >|= List.map E.Ctx.Lit.of_form
            >|= fun lits ->
                let cc = CompactClause.make (Array.of_list lits) [] in
                let proofs = proof_of_explanation p explanation in
                let proof = Proof.mk_c_inference ~rule:"lemma" cc proofs in
                cc, proof
           )
        ) consequences
      |> Sequence.to_list
    and axioms =
      Sequence.filter_map M.Plugin.axiom#of_fact facts
      |> Sequence.to_list
    and rewrite =
      Sequence.filter_map M.Plugin.rewrite#of_fact facts
      |> Sequence.to_list
    and pre_rewrite =
      Sequence.filter_map M.Plugin.pre_rewrite#of_fact facts
      |> Sequence.to_list
    in
    let r = { Result.theories; lemmas; axioms; rewrite; pre_rewrite ; } in
    p.new_results <- Result.merge_into r ~into:p.new_results;
    p.results <- Result.merge_into r ~into:p.results;
    (* trigger signals *)
    List.iter (Signal.send p.on_theory) r.Result.theories;
    List.iter (Signal.send p.on_axiom) r.Result.axioms;
    List.iter (Signal.send p.on_lemma) r.Result.lemmas;
    List.iter (Signal.send p.on_rewrite) r.Result.rewrite;
    List.iter (Signal.send p.on_pre_rewrite) r.Result.pre_rewrite;
    (* return new results *)
    r

  (* parse a theory file and update prover with it *)
  let parse_theory_file p filename =
    Util.debug ~section 1 "parse theory file %s" filename;
    CCError.(
      M.Prover.parse_file p.prover filename >|=
      fun (prover', consequences) ->
      (* update prover; return new results *)
      p.prover <- prover';
      let r = add_consequences p consequences in
      r
    )

  (* parse the given theory files into the prover *)
  let parse_theory_files p files =
    CCError.(fold_l
      (fun r f ->
        parse_theory_file p f
        >|= fun r' ->
        Result.merge_into r' ~into:r
      ) Result.empty files
    )

  let add_fact_ p fact =
    let prover', consequences = M.Prover.add_fact p.prover fact in
    p.prover <- prover';
    add_consequences p consequences

  (* scan the clause [c] with proof [proof] *)
  let scan_ p c proof =
    let fact =
      M.Encoding.foclause_of_clause c
      |> M.Plugin.holds#to_fact
    in
    (* save proof for later *)
    p.sources <- LitMap.add fact proof p.sources;
    add_fact_ p fact

  let scan_formula p f =
    Util.enter_prof prof_scan_formula;
    let form = PF.form f in
    let proof = PF.proof f in
    let r = scan_ p [form] proof in
    Util.exit_prof prof_scan_formula;
    r

  let scan_clause p c =
    Util.enter_prof prof_scan_clause;
    let proof = C.proof c in
    let c' =
      C.lits c
      |> Lits.Conv.to_forms ~hooks:(C.Ctx.Lit.to_hooks ())
    in
    let r = scan_ p c' proof in
    Util.exit_prof prof_scan_clause;
    r

  let declare_inductive p ity =
    let module CI = E.Ctx.Induction in
    let ity = Induction.make ity.CI.pattern ity.CI.constructors in
    Util.debugf ~section 2 "@[<hv2>declare inductive type@ %a@]" Induction.print ity;
    let fact = Induction.t#to_fact ity in
    add_fact_ p fact

  (* be sure to scan clauses *)
  let infer_scan p c =
    let r = scan_clause p c in
    if not (Result.is_empty r)
      then Util.debugf ~section 3 "@[scan@ %a@ →@ %a@]" C.fmt c Result.print r;
    []

  (** {6 Extension} *)

  (* global setup *)
  let setup () =
    clear_global ();
    let p = get_global () in
    Signal.on p.on_theory
      (fun th ->
         Util.debugf ~section 1 "detected theory %a" Result.pp_theory_axiom th;
         Signal.ContinueListening
      );
    (* declare inductive types *)
    E.Ctx.Induction.inductive_ty_seq
      (fun ity -> ignore (declare_inductive p ity));
    Signal.on E.Ctx.Induction.on_new_inductive_ty
      (fun ity ->
         ignore (declare_inductive p ity);
         Signal.ContinueListening
      );
    (* parse theory into [p] *)
    begin match parse_theory_files p !theory_files with
      | `Error msg ->
        Format.printf "error: %s@." msg;
        raise Exit
      | `Ok r ->
        if !flag_print_rules
        then Util.debugf ~section 1 "@[<v2>rules:@ %a@]" print_rules (reasoner p)
    end;
    (* register inferences *)
    E.add_unary_inf "meta.scan" (infer_scan p);
    (* printing *)
    Signal.once E.on_start
      (fun () ->
         if !flag_print_signature then
           Util.debugf ~section 1 "@[<hv2>signature:@,%a@]"
             Signature.fmt (M.Prover.signature (prover p))
      );
    Signal.once Signals.on_exit
      (fun _ ->
         if !flag_print_rules_exit then
         Util.debugf ~section 1 "@[<hv2>detected:@,%a@]" Result.print (results p)
      );
    ()
end

(** {2 Extension} *)

let extension =
  let action (module E: Env.S) =
    let module M = Make(E) in
    M.setup()
  in
  Extensions.( {
    default with
    name = "meta";
    actions=[Do action];
  })
