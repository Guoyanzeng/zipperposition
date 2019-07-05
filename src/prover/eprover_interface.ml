
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 boolean subterms} *)

open Logtk

let _tmp_dir = ref "/tmp"

module type S = sig
  module Env : Env.S

  (** {6 Registration} *)


  val set_e_bin : string -> unit
  val try_e : Env.C.t Iter.t -> Env.C.t Iter.t -> Env.C.t option

  val setup : unit -> unit
  (** Register rules in the environment *)
end

let _timeout = 4

let e_bin = ref (None : string option)

let regex_refutation = Str.regexp ".*SZS output start CNFRefutation.*" 
let reg_thf_clause = Str.regexp "thf(zip_cl_\\([0-9]+\\),.*"


module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module Ctx = Env.Ctx

  let output_empty_conj ~out =
    Format.fprintf out "thf(conj,conjecture,($false))."

  let output_cl ~out clause =
    let lits_converted = Literals.Conv.to_tst (C.lits clause) in
    Format.fprintf out "%% %d:\n" (Proof.Step.inferences_perfomed (C.proof_step clause));
    Format.fprintf out "@[thf(zip_cl_%d,axiom,@[%a@]).@]@\n" (C.id clause) TypedSTerm.TPTP_THF.pp lits_converted

  let output_symdecl ~out sym ty =
    Format.fprintf out "@[thf(@['%a_type',type,@[%a@]:@ @[%a@]@]).@]@\n" 
      ID.pp sym ID.pp_tstp sym (Type.TPTP.pp_ho) ty

  let output_all ~out cl_set =
    let cl_iter = Iter.of_list cl_set in
    let syms = ID.Set.to_list @@ C.symbols ~include_types:true cl_iter in
    (* first printing type declarations, and only then the types *)
    CCList.fold_right (fun sym acc -> 
      let ty = Ctx.find_signature_exn sym in
      if Type.is_tType ty then (
        output_symdecl ~out sym ty;
        acc
      ) else (
        assert (not ((Type.Seq.sub ty) |> Iter.exists (Type.is_tType)));
        Iter.cons (sym, ty) acc
      )
    ) syms Iter.empty
    |> Iter.iter (fun (sym, ty) -> output_symdecl ~out sym ty);

    Iter.iter (output_cl ~out) cl_iter;
    output_empty_conj ~out

  let set_e_bin path =
    e_bin := Some path 

  let run_e prob_path =
    match !e_bin with 
    | Some e_path -> 
      let cmd = CCFormat.sprintf "timeout %d %s %s --cpu-limit=%d --delete-bad-limit=2000000000  --definitional-cnf=24 -s  --proof-object=1  --auto  --split-clauses=4  --split-reuse-defs  --simul-paramod  --forward-context-sr  --destructive-er-aggressive  --destructive-er  --presat-simplify  --prefer-initial-clauses  --term-ordering=KBO6  -WSelectMaxLComplexAvoidPosPred  -winvfreqrank  -c1  -Ginvfreqconjmax  -F1 " _timeout e_path prob_path _timeout in
      CCFormat.printf "%% Running : %s.\n" cmd;
      let process_channel = Unix.open_process_in cmd in
      let _,status = Unix.wait () in
      begin match status with
      | WEXITED _ ->
        let refutation_found = ref false in
        (try 
          while not !refutation_found do 
            let line = input_line process_channel in
            flush_all ();
            if Str.string_match regex_refutation line 0 then 
              refutation_found := true;
          done;
          if !refutation_found then (
            let clause_ids = ref [] in
            (try 
              while true do 
                let line = input_line process_channel in
                flush_all ();
                if Str.string_match reg_thf_clause line 0 then (
                  let id = CCInt.of_string (Str.matched_group 1 line) in
                  clause_ids := CCOpt.get_exn id :: !clause_ids;)
              done;
              Some !clause_ids
             with End_of_file -> Some !clause_ids)
          ) else None
        with End_of_file -> None;)
      | _ -> None end
    | None ->
      invalid_arg "cannot run E if E binary is not set up"


  let try_e active_set passive_set =
    let max_others = 100 in

    let rec can_be_translated t =
      let can_translate_ty ty =
        Type.is_ground ty in

      let ty = Term.ty t in
      can_translate_ty ty &&
      match Term.view t with
      | AppBuiltin(b, [body]) when Builtin.is_quantifier b && Type.is_fun (Term.ty body) -> 
        let _, fun_body = Term.open_fun body in
        can_be_translated fun_body
      | AppBuiltin(b, l) -> (not (Builtin.is_logical_binop b) || List.length l >= 2) && 
                            (b != Builtin.Not || List.length l = 1) &&
                            List.for_all can_be_translated l
      | DB _ -> false
      | Var _ | Const _ -> true
      | App(hd,args) -> can_be_translated hd && List.for_all can_be_translated args
      | Fun _ -> false in


    let take_from_set set =
      let clause_no_lams cl =
        Iter.for_all can_be_translated (C.Seq.terms cl) in

      let reduced = 
        Iter.map (fun c -> CCOpt.get_or ~default:c (C.eta_reduce c)) set in
      let init_clauses = 
        Iter.filter (fun c -> C.proof_depth c = 0 && clause_no_lams c) reduced in
    
    Iter.append init_clauses (
      reduced
      |> Iter.filter (fun c -> 
        let proof_d = C.proof_depth c in
        let has_ho_step = Proof.Step.has_ho_step (C.proof_step c) in
        has_ho_step && proof_d  > 0 && clause_no_lams c)
      |> Iter.sort ~cmp:(fun c1 c2 ->
          let pd1 = C.proof_depth c1 and pd2 = C.proof_depth c2 in
          CCInt.compare pd1 pd2)
      |> Iter.take max_others)
    |> Iter.to_list in

    let prob_name, prob_channel = Filename.open_temp_file ~temp_dir:!_tmp_dir "e_input" "" in
    let out = Format.formatter_of_out_channel prob_channel in
    let cl_set = take_from_set active_set @ (take_from_set passive_set) in
    output_all ~out cl_set;
    close_out prob_channel;

    let res = 
      match run_e prob_name with
      | Some ids ->
        assert(not (CCList.is_empty ids));
        
        let clauses = List.map (fun id -> 
          List.find (fun cl -> (C.id cl) = id) cl_set) ids in
        let rule = Proof.Rule.mk "eprover" in
        let proof = Proof.Step.inference  ~rule (List.map C.proof_parent clauses) in
        let penalty = CCOpt.get_exn @@ Iter.max (Iter.map C.penalty (Iter.of_list clauses)) in
        let trail = C.trail_l clauses in
        Some (C.create ~penalty ~trail [] proof)
      | _ -> None 
    in
    (* Sys.remove prob_name; *)
    res
    
  let setup () = 
    ()
end

let () =
   Options.add_opts
    [ "--tmp-dir", Arg.String (fun v -> _tmp_dir := v), " scratch directory for running E" ]
