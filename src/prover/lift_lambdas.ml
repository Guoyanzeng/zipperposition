open Logtk
module T = Term

let section = Util.Section.make ~parent:Const.section "live_lifting"

let k_live_lifting = Flex_state.create_key ()

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  (** {6 Registration} *)
  val setup : unit -> unit
  val lift_lambdas : Env.C.t -> Env.C.t list
end


module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module Ctx = Env.Ctx
  module Idx = Fingerprint.Make(struct 
    type t = C.t * T.t
    let (<?>) = (CCOrd.Infix.(<?>)) 
    let compare (a,b) (c,d) =
      (C.compare a c) <?> (T.compare, b, d)
   end)

  let setup () = ()
  
  let sc t = (t, 0)

  let idx = ref (Idx.empty ())

  let loose_bound_to_fvars ~counter t =
    let rec aux ~depth ~lb_map ~subst t =
      match T.view t with
      | DB i ->
        if i < depth then t, lb_map, subst
        else (
          let i = i - depth in
          match Util.Int_map.get i lb_map  with 
          | Some var -> 
            assert(not @@ Scoped.equal T.equal (sc var) (Subst.FO.deref subst (sc var)));
            var, lb_map, subst
          | None  ->
            let fvar = HVar.fresh_cnt ~counter ~ty:(T.ty t) () in
            let t' = T.var fvar in
            let lb_map = Util.Int_map.add i t' lb_map in 
            let unshifted = T.bvar ~ty:(T.ty t) i in
            let subst = Subst.FO.bind' subst (sc fvar) (sc unshifted) in
            t', lb_map, subst
        )
      | Const _ | Var _ -> t, lb_map, subst
      | T.Fun _ ->
        let prefs, body = T.open_fun t in
        let depth_inc = List.length prefs in
        let body', lb_map, subst = aux ~depth:(depth+depth_inc) ~lb_map ~subst body in
        T.fun_l prefs body', lb_map, subst
      | AppBuiltin(b, l) -> 
        let l', lb_map, subst = aux_l ~depth ~lb_map ~subst l in
        T.app_builtin ~ty:(T.ty t) b l', lb_map, subst
      | App(hd, l ) ->
        let hd', lb_map, subst = aux ~depth ~lb_map ~subst hd in
        let l', lb_map, subst = aux_l ~depth ~lb_map ~subst l in
        T.app hd' l', lb_map, subst
    and aux_l ~depth ~lb_map ~subst = function 
      | [] -> [], lb_map, subst
      | x :: xs -> 
        let x', lb_map, subst = aux ~depth ~lb_map ~subst x in
        let xs', lb_map, subst = aux_l ~depth ~lb_map ~subst xs in
        x'::xs', lb_map, subst in
    aux t ~depth:0 ~lb_map:Util.Int_map.empty ~subst:Subst.empty
    

let fully_apply ~counter s t  =
  assert(Type.equal (T.ty s) (T.ty t));
  if not (Type.is_fun (T.ty t)) then  (s,t)
  else (
    let tys,_ = Type.open_fun (T.ty t) in
    let fresh_vars = List.map (fun ty -> T.var (HVar.fresh_cnt ~counter ~ty ())) tys in
    Lambda.whnf @@ T.app s fresh_vars, Lambda.whnf @@ T.app t fresh_vars
  )

let lift_lambdas_t ~counter t  =
  let rec aux t =
    match T.view t with
    | T.Fun _ ->
      Util.debugf ~section 1 "before lifting:@[%a@]@." (fun k -> k T.pp t);
      let pref_vars, body = T.open_fun t in
      let body', (reused_defs,new_defs) = aux body in
      let body_closed = T.fun_l pref_vars body' in
      Util.debugf ~section 1 "after lifting:@[%a@]@." (fun k -> k T.pp body_closed);
      let generalization = 
        Idx.retrieve_generalizations (!idx, 1) (body_closed, 0)
        |> Iter.head in
      begin match generalization with 
      | Some (_,(def, lhs),subst) ->
        let lits = C.lits def in
        assert(Array.length lits = 1);
        let lhs' = Subst.FO.apply Subst.Renaming.none subst (lhs, 1) in
        lhs', (def :: reused_defs, new_defs)
      | None -> 
        let free_vars = T.vars body' in
        let unbound, _, subst = loose_bound_to_fvars ~counter body_closed in
        let new_free_vars = T.VarSet.diff (T.vars unbound) (free_vars) in
        let all_vars = T.VarSet.to_list free_vars @ T.VarSet.to_list new_free_vars in
        let (id, ty), new_ll_sym = 
          T.mk_fresh_skolem ~prefix:"l_lift" all_vars (T.ty t) in
        Ctx.declare id ty;
        let lhs = new_ll_sym and rhs = unbound in
        let lhs_applied, rhs_applied = fully_apply ~counter lhs rhs in
        let lits = [Literal.mk_eq lhs_applied rhs_applied] in
        let proof = Proof.Step.define_internal id [] in
        let new_def = C.create ~penalty:1 ~trail:Trail.empty lits proof in
        let repl = Subst.FO.apply Subst.Renaming.none subst (sc lhs) in
        idx := Idx.add !idx rhs (new_def, lhs);
        repl, (reused_defs, (new_def :: new_defs))
        end
    | T.Var _ | T.Const _  | T.DB _ -> t, ([],[])
    | T.App(hd, l) -> 
      assert(not (T.is_fun hd));
      let l', new_defs = aux_l l in
      T.app hd l', new_defs
    | T.AppBuiltin(b, l) ->
      let l', new_defs = aux_l l in
      T.app_builtin ~ty:(T.ty t) b l', new_defs
  and aux_l = function 
    | [] -> ([], ([],[]))
    | x :: xs ->
      let x', (x_reused_defs, x_new_defs) = aux x in
      let xs', (xs_reused_defs, xs_new_defs) = aux_l xs in
      x' :: xs', (x_reused_defs @ xs_reused_defs, x_new_defs @ xs_new_defs) in
  Util.debugf ~section 1 "lifting @[%a@]@." (fun k -> k T.pp t);
  aux t

  let lift_lambdas cl =
    let counter = 
      ref ((C.Seq.vars cl |> Iter.map HVar.id 
            |> Iter.max |> CCOpt.get_or ~default:0) + 1) in
    let lits, (reused_defs, new_defs) = 
      C.lits cl
      |> CCArray.to_list
      |> (fun l -> List.fold_right (fun lit (acc, (reused_defs, new_defs)) -> 
          match lit with 
          | Literal.Equation(lhs, rhs, sign) ->
            let lhs', (reused_lhs, new_lhs) = lift_lambdas_t ~counter lhs in
            let rhs', (reused_rhs, new_rhs) = lift_lambdas_t ~counter rhs in
            let reused = reused_lhs @ reused_rhs and new_ = new_rhs @ new_lhs in
            let lit' = Literal.mk_lit lhs' rhs' sign in
            lit'::acc, (reused@reused_defs, new_@new_defs)
          | _ -> lit::acc, (reused_defs, new_defs)
       ) l ([],([],[]))) in
    if CCList.is_empty reused_defs && CCList.is_empty new_defs then []
    else (
      let proof = 
        Proof.Step.simp 
          ~tags:[Proof.Tag.T_ho] ~rule:(Proof.Rule.mk "lambda_lifting")
          (List.map C.proof_parent (cl :: reused_defs @ new_defs)) in
      let lifted =
        C.create ~penalty:(C.penalty cl) ~trail:(C.trail cl) lits proof in
      
      lifted :: new_defs
  )

  let lift_lambdas_simp cl =
    let res = lift_lambdas cl in
    if CCList.is_empty res then (
      Util.debugf ~section 1 "Nothing to do for @[%a@]@." (fun k -> k C.pp cl);
      None)
    else (
      Util.debugf ~section 1 "lifting(@[%a@])@. = @[%a@]" (fun k -> k C.pp cl (CCList.pp C.pp) res);
      Some res)

  let setup () =
    if Env.flex_get k_live_lifting then (
      Env.add_multi_simpl_rule lift_lambdas_simp
    );
end

let _live_lifting = ref false

let extension =
  let register env =
    let module E = (val env : Env.S) in
    let module ET = Make(E) in

    E.flex_add k_live_lifting !_live_lifting;
    ET.setup ()
  in
  { Extensions.default with
    Extensions.name = "lift_lambdas";
    env_actions=[register];
  }

let () =
  Options.add_opts
    [ "--live-lambda-lifting", Arg.Bool ((:=) _live_lifting), 
      " enable/disable lambda lifting as simplifying inference";
    ];
  Params.add_to_modes ["ho-complete-basic";
                       "ho-pragmatic";
                       "lambda-free-intensional";
                       "lambda-free-purify-intensional";
                       "lambda-free-extensional";
                       "ho-comb-complete";
                       "lambda-free-purify-extensional";
                       "fo-complete-basic"] (fun () ->
      _live_lifting := false
  );

  Extensions.register extension;