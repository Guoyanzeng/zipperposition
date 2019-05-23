
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Terms} *)

module PB = Position.Build
module PW = Position.With
module T = InnerTerm

let prof_app = Util.mk_profiler "term.app"
let prof_ac_normal_form = Util.mk_profiler "term.AC_normal_form"

(** {2 Term} *)

type t = T.t

type term = t
type var = Type.t HVar.t

type view =
  | AppBuiltin of Builtin.t * t list
  | DB of int (** Bound variable (De Bruijn index) *)
  | Var of var (** Term variable *)
  | Const of ID.t (** Typed constant *)
  | App of t * t list (** Application to a list of terms (cannot be left-nested) *)
  | Fun of Type.t * t (** Lambda abstraction *)

let view t = match T.view t with
  | T.AppBuiltin (b,l) -> AppBuiltin (b,l)
  | T.Var v -> Var (Type.cast_var_unsafe v)
  | T.DB i -> DB i
  | T.App (_, []) -> assert false
  | T.App (f, l) -> App (f, l)
  | T.Const s -> Const s
  | T.Bind (Binder.Lambda, ty, t') -> Fun (Type.of_term_unsafe ty, t')
  | _ -> assert false

(** {2 Comparison, equality, containers} *)

let subterm ~sub t =
  let rec check t =
    T.equal sub t ||
    match T.view t with
      | T.Var _ | T.DB _ | T.Const _ -> false
      | T.App (f, l) -> check f || List.exists check l
      | T.Bind (_, _, t') -> check t'
      | T.AppBuiltin (_,l) -> List.exists check l
  in
  check t

let equal = T.equal
let hash = T.hash
let compare = T.compare
let[@inline] ty t = match T.ty t with
  | T.NoType -> assert false
  | T.HasType ty -> Type.of_term_unsafe ty

let hash_mod_alpha = T.hash_mod_alpha
let same_l = T.same_l

(* split list between types, terms.
   [ty] is the type of the function, [l] the arguments *)
let rec split_args_ ~ty l = match Type.view ty, l with
  | Type.Forall ty', x :: l' ->
    let l1, l2 = split_args_ ~ty:ty' l' in
    x :: l1, l2
  | _ -> [], l

module Classic = struct
  type view =
    | Var of var
    | DB of int
    | App of ID.t * t list (** covers Const and App *)
    | AppBuiltin of Builtin.t * t list
    | NonFO (** any other case *)

  let view t : view = match T.view t with
    | T.Var v -> Var (Type.cast_var_unsafe v)
    | T.DB i -> DB i
    | _ when not (Type.is_unifiable @@ ty t) -> NonFO
    | T.Const s -> App (s,[])
    | T.AppBuiltin (b,l) -> AppBuiltin (b,l)
    | T.App (f, l) ->
      begin match T.view f with
        | T.Const id -> App (id, l)
        | _ -> NonFO
      end
    | T.Bind (Binder.Lambda, _, _) -> NonFO
    | T.Bind (_,_,_) -> assert false
end

(** {2 Containers} *)
module IntMap = Map.Make(CCInt)

module Tbl = T.Tbl
module Set = T.Set
module Map = T.Map

module VarSet = Type.VarSet
module VarMap = Type.VarMap
module VarTbl = Type.VarTbl


(** {2 Smart constructors} *)

(** In this section, term smart constructors are defined. They perform
    hashconsing, and precompute some properties (flags). *)

let var = (T.var :> var -> T.t)

let var_of_int ~ty i =
  let ty = (ty : Type.t :> T.t) in
  T.var (HVar.make ~ty i)

let builtin ~ty b = T.builtin ~ty:(ty : Type.t :> T.t) b

let app_builtin ~ty b l = T.app_builtin ~ty:(ty : Type.t :> T.t) b l

let bvar ~ty i =
  assert (i >= 0);
  T.bvar ~ty:(ty : Type.t :> T.t) i

let const ~ty s =
  T.const ~ty:(ty : Type.t :> T.t) s

let tyapp t args = match args with
  | [] -> t
  | _::_ ->
    let args' = (args : Type.t list :> T.t list) in
    let ty = (Type.apply (ty t) args : Type.t :> T.t) in
    T.app ~ty t args'

let app f l = match l with
  | [] -> f
  | _::_ ->
    Util.enter_prof prof_app;
    (* first; compute type *)
    let ty_result = Type.apply_unsafe (ty f) l in
    (* apply constant to type args and args *)
    let res = T.app ~ty:(ty_result : Type.t :> T.t) f l in
    Util.exit_prof prof_app;
    res

let app_w_ty ~ty f l  = match l with
  | [] -> f
  | _::_ ->
    Util.enter_prof prof_app;
    (* first; compute type *)
    let ty_result = Type.apply_unsafe ty l in
    (* apply constant to type args and args *)
    let res = T.app ~ty:(ty_result : Type.t :> T.t) f l in
    Util.exit_prof prof_app;
    res


let app_full f tyargs l =
  let l = (tyargs : Type.t list :> T.t list) @ l in
  app f l

let fun_ (ty_arg:Type.t) body =
  T.fun_ (ty_arg:>T.t) body

let fun_l ty_args body = List.fold_right fun_ ty_args body

let fun_of_fvars vars body =
  let vars = (vars : Type.t HVar.t list :> T.t HVar.t list) in
  T.fun_of_fvars vars body

let open_fun t =
  let tys, bod = T.open_bind Binder.Lambda t in
  Type.of_terms_unsafe tys, bod

let open_fun_offset ~offset t =
  let rec aux offset env vars t = match view t with
    | Fun (ty_var, body) ->
      let v = HVar.make offset ~ty:ty_var in
      let env = DBEnv.push env (var v) in
      aux (offset+1) env (v::vars) body
    | _ ->
      let t' = T.DB.eval env t in
      List.rev vars, t', offset
  in
  aux offset DBEnv.empty [] t

let true_ = builtin ~ty:Type.prop Builtin.True
let false_ = builtin ~ty:Type.prop Builtin.False

let grounding ty = builtin ~ty Builtin.Grounding

let is_formula t = match T.view t with
  | T.AppBuiltin(hd,_) ->
    List.mem hd [Builtin.And; Builtin.Or; Builtin.Not; 
                 Builtin.Imply; Builtin.Equiv; 
                 Builtin.Xor; Builtin.ForallConst;
                 Builtin.ExistsConst]
  | _ -> false

let is_var t = match T.view t with
  | T.Var _ -> true
  | _ -> false

let is_bvar t = match T.view t with
  | T.DB _ -> true
  | _ -> false

let is_const t = match T.view t with
  | T.Const _ -> true
  | _ -> false

let is_fun t = match T.view t with
  | T.Bind (Binder.Lambda, _, _) -> true
  | _ -> false

let is_app t = match T.view t with
  | T.Const _
  | T.App _ -> true
  | _ -> false

let get_quantified_var t = match T.view t with
  | T.AppBuiltin(Builtin.ForallConst, [x;_])
  | T.AppBuiltin(Builtin.ExistsConst, [x;_]) when is_var x ->
      Some x
  | _ -> None

let is_type t = Type.equal Type.tType (ty t)

let as_const_exn t = match T.view t with
  | T.Const c -> c
  | _ -> invalid_arg (CCFormat.sprintf "as_const_exn: %a" T.pp t)

let as_const t = try Some (as_const_exn t) with Invalid_argument _ -> None

let as_var_exn t = match T.view t with
  | T.Var v -> (Type.cast_var_unsafe v)
  | _ -> invalid_arg "as_var_exn"

let as_var t = try Some (as_var_exn t) with Invalid_argument _ -> None

let as_app = T.as_app
let as_bvar_exn = T.as_bvar_exn

let rec as_fun t = match view t with
  | Fun (ty_arg, bod) ->
    let args, ret = as_fun bod in
    ty_arg :: args, ret
  | _ -> [], t

let head_term t = fst (as_app t)
let args t = snd (as_app t)

let is_app_var t = is_var @@ head_term t &&
                   List.length @@ args t > 0

let head_term_mono t = match view t with
  | App (f,l) ->
    let l1 = CCList.take_while is_type l in
    app f l1 (* re-apply to type parameters *)
  | _ -> t

let get_mand_args t =
  match view t with
    | App (f,l) ->
      let num_mand_args =
        begin match as_const f with
          | Some id -> ID.num_mandatory_args id
          | None -> 0
        end
      in
      let _, other_args = CCList.take_drop_while is_type l in
      let mand_args, _ = CCList.take_drop num_mand_args other_args in
      mand_args
    | _ -> []


let as_app_with_mandatory_args t =
  match view t with
    | App (f,l) ->
      let num_mand_args =
        begin match as_const f with
          | Some id -> ID.num_mandatory_args id
          | None -> 0
        end
      in
      let ty_args, other_args = CCList.take_drop_while is_type l in
      let mand_args, other_args = CCList.take_drop num_mand_args other_args in
      assert (List.for_all T.DB.closed mand_args);
      let head = app f (ty_args @ mand_args) in (* re-apply to type & mandatory args *)
      head, other_args
    | _ -> t, []

let head_term_with_mandatory_args t = fst (as_app_with_mandatory_args t)

let is_ho_var t = match view t with
  | Var v -> Type.needs_args (HVar.ty v)
  | _ -> false

let as_ho_app t =
  let hd, args = as_app t in
  begin match as_var hd with
    | Some v when args<> [] -> Some (v, args)
    | _ -> None
  end

let is_ho_app t = CCOpt.is_some (as_ho_app t)

let is_ho_pred t = is_ho_app t && Type.is_prop (ty t)

let is_ho_at_root t = is_ho_var t || is_ho_app t

let rec all_combs = function 
  | [] -> []
  | x::xs ->
      let rest_combs = all_combs xs in
      if CCList.is_empty rest_combs then CCList.map (fun t->[t]) x 
      else CCList.flat_map 
            (fun i -> CCList.map (fun comb -> i::comb) rest_combs) 
           x

let rec cover_with_terms ?(depth=0) ?(recurse=true) t ts =
  let n = List.length ts in
  let db = CCList.mapi (fun i x -> 
              if CCOpt.is_some x then (i, CCOpt.get_exn x) else (-1, false_)) 
           ts
           |> CCList.filter_map (fun (i,x) ->
                if i!=(-1) && equal x t then 
                (assert (Type.equal (ty x) (ty t));
                Some (bvar ~ty:(ty t) (n-1-i+depth))) 
                else None) in
  let rest =
    if recurse then 
      begin match view t with 
        | AppBuiltin (hd,args) ->
            if CCList.is_empty args then [app_builtin ~ty:(ty t) hd []]
            else (
              let args' = List.map (fun a -> cover_with_terms ~depth a ts) args in
              let args_combined = all_combs args' in
              List.map (fun args -> app_builtin ~ty:(ty t) hd args) args_combined
            )
        | App (_,args) ->
            assert(not (CCList.is_empty args));
            let hd, args = head_term_mono t, CCList.drop_while is_type args in
            let hd' = cover_with_terms ~recurse:false hd ts in
            let args' = List.map (fun a -> cover_with_terms ~depth a ts) args in
            let args_combined = all_combs (hd'::args') in
            List.map (fun l ->  app (List.hd l) (List.tl l)) args_combined
        | Fun (ty_var, body) -> 
            let bodies = cover_with_terms ~depth:(depth+1) body ts in
            assert(not (CCList.is_empty bodies));
            List.map (fun b -> fun_ ty_var b) bodies
        | _ -> [t]
      end
    else [t] in
  db @ rest

let max_cover t ts =
  let rec aux depth t =
    let hit = CCList.find_mapi (fun i x -> 
        match x with
        | Some t' when equal t t' -> Some i
        | _ -> None) ts in 
    match hit with
    | Some idx -> bvar ~ty:(ty t) (List.length ts - 1 - idx + depth)
    | None -> 
      begin match view t with
      | AppBuiltin (hd,args) -> 
        let args' = List.map (fun arg -> aux depth arg) args in
        app_builtin ~ty:(ty t) hd args'
      | App (hd,args) -> 
        let args' = List.map (fun arg -> aux depth arg) args in
        app (aux depth hd) args'
      | Fun (ty_var, body) -> 
        let body' = aux (depth+1) body in
        fun_ ty_var body'
      | DB _ | Var _  | Const _ -> t
      end
  in
  aux 0 t


module Seq = struct
  let vars t k =
    let rec aux t =
      Type.Seq.vars (ty t) k;
      aux_term t;
    and aux_term t = match view t with
      | Var v -> k v
      | Const _
      | DB _ -> ()
      | Fun (_,u) -> aux_term u
      | App (f, l) ->
        aux f;
        List.iter aux l
      | AppBuiltin (_,l) -> List.iter aux l
    in
    aux t

  let subterms ?(include_builtin=false) t k =
    let rec aux t =
      k t;
      match view t with
        | AppBuiltin (_, l) -> if include_builtin then List.iter aux l;
        | Const _
        | Var _
        | DB _ -> ()
        | Fun (_, u) -> aux u
        | App (f, l) -> aux f; List.iter aux l
    in
    aux t

  let subterms_depth t k =
    let rec recurse depth t =
      k (t, depth);
      match view t with
        | Const _
        | DB _
        | Var _ -> ()
        | Fun (_,u) -> recurse (depth+1) u
        | AppBuiltin (_, l) -> List.iter (recurse (depth+1)) l
        | App (_, l) ->
          let depth' = depth + 1 in
          List.iter (recurse depth') l
    in
    recurse 0 t

  let symbols t k =
    let rec aux t = match view t with
      | AppBuiltin (_,l) -> List.iter aux l
      | Const s -> k s
      | Var _
      | DB _ -> ()
      | Fun (_,u) -> aux u
      | App (f, l) -> aux f; List.iter aux l
    in
    aux t

  let max_var = Type.Seq.max_var
  let min_var = Type.Seq.min_var

  let add_set set xs =
    Iter.fold (fun set x -> Set.add x set) set xs

  let ty_vars t =
    subterms t
    |> Iter.flat_map (fun t -> Type.Seq.vars (ty t))

  let typed_symbols t =
    subterms t
    |> Iter.filter_map
      (fun t -> match T.view t with
         | T.Const s -> Some (s, ty t)
         | _ -> None)
end

let vars_under_quant t = VarSet.of_seq @@ Iter.fold (fun acc st -> 
  match view st with 
  | AppBuiltin(Builtin.ForallConst, [x;_]) 
  | AppBuiltin(Builtin.ExistsConst, [x;_]) when is_var x  ->
    Iter.union acc (Seq.vars x)
  | _ -> acc
) Iter.empty (Seq.subterms ~include_builtin:true t)


let var_occurs ~var t =
  Iter.exists (HVar.equal Type.equal var) (Seq.vars t)

let rec size t = match view t with
  | Var _
  | DB _ -> 1
  | AppBuiltin (_,l)
  | App (_, l) -> List.fold_left (fun s t' -> s + size t') 1 l
  | Fun (_,u) -> 1 + size u
  | Const _ -> 1

let weight ?(var=1) ?(sym=fun _ -> 1) t =
  let rec weight t = match view t with
    | Var _
    | DB _ -> var
    | AppBuiltin (_,l)
    | App (_, l) -> List.fold_left (fun s t' -> s + weight t') 1 l
    | Fun (_, u) -> 1 + weight u
    | Const s -> sym s
  in weight t

let is_ground t = T.is_ground t

let rec in_pfho_fragment t =
   match view t with
    | Var _ -> if (not (type_ok (ty t))) then
               (raise (Failure (CCFormat.sprintf "Variable has wrong type [%a]" T.pp t)))
               else true
    | Const sym -> if (List.for_all type_ok (Type.expected_args (ty t))) then true
                 else (raise (Failure (CCFormat.sprintf "Constant has wrong type [%a] " ID.pp sym)))
    | AppBuiltin( _, l)
    | App (_, l) -> let hd = head_term t in
                    let hd_is_skolem = match as_const hd with
                                    | Some sym -> ID.is_skolem sym
                                    | None -> false in
                    if((not (is_var hd || hd_is_skolem) || type_ok (ty t)) &&
                      List.map ty l |> List.for_all type_ok
                    && List.for_all in_pfho_fragment l) then true
                    else (raise (Failure (CCFormat.sprintf "Arugment of a term has wrong type [%a]" T.pp t)))
    | Fun (var_t, body) -> if(type_ok (var_t) &&
                           type_ok (ty body) &&
                           in_pfho_fragment body) then true
                           else (raise (Failure (CCFormat.sprintf "Lambda body has wrong type [%a]" T.pp t)))
    | DB _ -> if(type_ok (ty t)) then true
              else (raise (Failure "Bound variable has wrong type"))
   and type_ok ty_ =
    not (Type.Seq.sub ty_ |> Iter.mem ~eq:Type.equal (Type.prop)) &&
    not (Type.Seq.sub ty_ |> Iter.mem ~eq:Type.equal (Type.tType))

let in_lfho_fragment t =
   in_pfho_fragment t &&
      (Seq.subterms t) |>
      (fun subts ->
         if Iter.for_all (fun subt -> not (is_fun subt)) subts
         then true
         else raise (Failure "has lambda"))

let rec is_fo_term t =
  match view t with
  | Var _ -> not @@ Type.is_fun @@ ty t
  | AppBuiltin (_,l) -> List.for_all is_fo_term l
  | App (hd, l) -> let expected_args = List.length @@ Type.expected_args @@ ty hd in
                   let actual_args = List.length l in
                   expected_args = actual_args &&
                     List.for_all is_fo_term (hd :: l)
  | Const _ -> true
  | _ -> false


let monomorphic t = Iter.is_empty (Seq.ty_vars t)

let max_var set = VarSet.to_seq set |> Seq.max_var

let min_var set = VarSet.to_seq set |> Seq.min_var

let add_vars tbl t = Seq.vars t (fun v -> VarTbl.replace tbl v ())

let vars ts = Seq.vars ts |> VarSet.of_seq

let vars_prefix_order t =
  Seq.vars t
  |> Iter.fold (fun l x -> if not (List.memq x l) then x::l else l) []
  |> List.rev

let depth t = Seq.subterms_depth t |> Iter.map snd |> Iter.fold max 0


(* @param vars the free variables the parameter must depend upon
   @param ty_ret the return type *)
let mk_fresh_skolem =
   let n = ref 0 in
   fun vars ty_ret ->
   let i = CCRef.incr_then_get n in
   (** fresh skolem **)
   let id = ID.makef "#fsk%d" i in
   ID.set_payload id (ID.Attr_skolem (ID.K_normal, i));
   let ty_vars, vars =
      List.partition (fun v -> Type.is_tType (HVar.ty v)) vars
   in
   let ty =
      Type.forall_fvars ty_vars
         (Type.arrow (List.map HVar.ty vars) ty_ret)
   in
   app_full (const id ~ty)
      (List.map Type.var ty_vars)
      (List.map var vars)

let rec head_exn t = match T.view t with
  | T.Const s -> s
  | T.App (hd,_) -> head_exn hd
  | _ -> invalid_arg "Term.head"

let head t =
  try Some (head_exn t)
  with Invalid_argument _-> None

let ty_vars t = Seq.ty_vars t |> Type.VarSet.of_seq

let of_term_unsafe t = t
let of_term_unsafe_l l = l

let of_ty t = (t : Type.t :> T.t)

(** {2 Subterms and positions} *)

module Pos = struct
  let at t pos = of_term_unsafe (T.Pos.at (t :> T.t) pos)

  let replace t pos ~by =
    assert (Type.equal (at t pos |> ty) (ty by));
    of_term_unsafe (T.Pos.replace (t:>T.t) pos ~by:(by:>T.t))
end

let replace t ~old ~by =
  assert (Type.equal (ty by) (ty old));
  of_term_unsafe (T.replace (t:t:>T.t) ~old:(old:t:>T.t) ~by:(by:t:>T.t))

let replace_m t m =
  of_term_unsafe (T.replace_m (t:t:>T.t) (m:t Map.t:>T.t T.Map.t))

let symbols ?(init=ID.Set.empty) t =
  ID.Set.add_seq init (Seq.symbols t)

(** Does t contains the symbol f? *)
let contains_symbol f t =
  Iter.exists (ID.equal f) (Seq.symbols t)

(** {2 Fold} *)

let all_positions ?(vars=false) ?(ty_args=true) ?(var_args=true) ?(fun_bodies=true) ?(pos=Position.stop) t f =
  let rec aux pb t = match view t with
    | Var _ | DB _ ->
      if vars && (ty_args || not (Type.is_tType (ty t)))
      then f (PW.make t (PB.to_pos pb))
    | Const _ ->
      if ty_args || not (Type.is_tType (ty t))
      then f (PW.make t (PB.to_pos pb))
    | Fun (_, u) ->
      f (PW.make t (PB.to_pos pb));
      if fun_bodies
      then aux (PB.body pb) u
    | App (head, _) when not var_args && T.is_var head ->
      f (PW.make t (PB.to_pos pb))
    | AppBuiltin (_, args)
    | App (_, args) ->
        if ty_args || not (Type.is_tType (ty t)) then (
          f (PW.make t (PB.to_pos pb));
        );
        let len = List.length args in
        let invi i = len - 1 - i in
        List.iteri
          (fun i t' ->
              (* if [t'] is a type parameter and [not ty_args], ignore *)
              if ty_args || not (Type.is_tType (ty t'))
              then aux (PB.arg (invi i) pb) t')
          args
  in
  aux (PB.of_pos pos) t

(** {2 Some AC-utils} *)

module type AC_SPEC = sig
  val is_ac : ID.t -> bool
  val is_comm : ID.t -> bool
end

module AC(A : AC_SPEC) = struct
  let flatten f l =
    let rec flatten acc l = match l with
      | [] -> acc
      | x::l' -> flatten (deconstruct acc x) l'
    and deconstruct acc t = match T.view t with
      | T.App (f', l') ->
        begin match head f' with
          | Some id when ID.equal id f ->
            let _, args = split_args_ ~ty:(ty f') l' in
            flatten acc args
          | Some _ | None -> t::acc
        end
      | _ -> t::acc
    in flatten [] l

  let normal_form t =
    Util.enter_prof prof_ac_normal_form;
    let rec normalize t = match T.view t with
      | T.Const _
      | T.Var _
      | T.DB _ -> t
      | T.App (f, l) when T.is_const f && A.is_ac (head_exn f) ->
        let l = flatten (head_exn f) l in
        let tyargs, l = split_args_ ~ty:(ty f) l in
        let l = List.map normalize l in
        let l = List.sort compare l in
        begin match l with
          | x::l' ->
            let ty = T.ty_exn t in
            let tyargs = (tyargs :> T.t list) in
            List.fold_left
              (fun subt x -> T.app ~ty f (tyargs@[x;subt]))
              x l'
          | [] -> assert false
        end
      | T.App (f, l) when T.is_const f && A.is_comm (head_exn f) ->
        let tyargs, l = split_args_ ~ty:(ty f) l in
        begin match l with
          | [a;b] ->
            let a' = normalize a in
            let b' = normalize b in
            if compare a' b' > 0
            then T.app ~ty:(ty t :>T.t) f (tyargs @ [b'; a'])
            else if T.equal a a' && T.equal b b' then t
            else T.app ~ty:(ty t :>T.t) f (tyargs @ [a'; b'])
          | _ -> t  (* partially applied *)
        end
      | T.App (f, l) ->
        let l = List.map normalize l in
        T.app ~ty:(T.ty_exn t) f l
      | T.AppBuiltin (b,l) ->
        let l = List.map normalize l in
        T.app_builtin ~ty:(T.ty_exn t) b l
      | T.Bind (b, varty, body) ->
        T.bind ~ty:(T.ty_exn t) ~varty b (normalize body)
    in
    let t' = normalize t in
    Util.exit_prof prof_ac_normal_form;
    t'

  let equal t1 t2 =
    let t1' = normal_form t1
    and t2' = normal_form t2 in
    equal t1' t2'

  let seq_symbols t =
    Seq.symbols t
    |> Iter.filter A.is_ac

  let symbols seq =
    seq
    |> Iter.flat_map seq_symbols
    |> ID.Set.add_seq ID.Set.empty
end

(** {2 Printing/parsing} *)

let print_all_types = T.print_all_types

type print_hook = int -> (CCFormat.t -> t -> unit) -> CCFormat.t -> t -> bool

(* lightweight printing *)
let pp_depth = T.pp_depth

let pp_var out (v:Type.t HVar.t) = T.pp_var out (v :> T.t HVar.t)

let add_hook = T.add_default_hook
let default_hooks = T.default_hooks

let pp out t = pp_depth 0 out t

let to_string = CCFormat.to_string pp

(** {2 Form} *)

module Form = struct
  let pp_hook _depth pp_rec out t =
    match Classic.view t with
      | Classic.AppBuiltin (Builtin.Not, [a]) ->
        Format.fprintf out "(@[<1>¬@ %a@])" pp_rec a; true
      | _ -> false  (* default *)

  let () = add_hook pp_hook

  let not_ t: t =
    assert (Type.is_prop (ty t));
    match view t with
      | AppBuiltin (Builtin.Not, [u]) -> u
      | _ -> app_builtin ~ty:Type.prop Builtin.not_ [t]

  let eq a b =
    assert (Type.equal (ty a)(ty b));
    app_builtin ~ty:Type.prop Builtin.eq [of_ty (ty a); a; b]

  let neq a b =
    assert (Type.equal (ty a)(ty b));
    app_builtin ~ty:Type.prop Builtin.neq [of_ty (ty a); a; b]

  let and_ a b =
    assert (Type.is_prop (ty a) && Type.is_prop (ty b));
    app_builtin ~ty:Type.prop Builtin.and_ [a; b]

  let or_ a b =
    assert (Type.is_prop (ty a) && Type.is_prop (ty b));
    app_builtin ~ty:Type.prop Builtin.or_ [a; b]

  let and_l = function
    | [] -> true_
    | [t] -> t
    | a :: tail -> List.fold_left and_ a tail
  let or_l = function
    | [] -> false_
    | [t] -> t
    | a :: tail -> List.fold_left or_ a tail
end

(** {2 Arith} *)

module Arith = struct
  let ty1 = Type.(forall ([int] ==> bvar 0))

  let floor = builtin ~ty:ty1 Builtin.Arith.floor
  let ceiling = builtin ~ty:ty1 Builtin.Arith.ceiling
  let truncate = builtin ~ty:ty1 Builtin.Arith.truncate
  let round = builtin ~ty:ty1 Builtin.Arith.round

  let prec = builtin ~ty:Type.([int] ==> int) Builtin.Arith.prec
  let succ = builtin ~ty:Type.([int] ==> int) Builtin.Arith.succ

  let ty2 = Type.(forall ([bvar 0; bvar 0] ==> bvar 0))
  let ty2i = Type.([int;int] ==> int)

  let sum = builtin ~ty:ty2 Builtin.Arith.sum
  let difference = builtin ~ty:ty2 Builtin.Arith.difference
  let uminus = builtin ~ty:ty2 Builtin.Arith.uminus
  let product = builtin ~ty:ty2 Builtin.Arith.product
  let quotient = builtin ~ty:ty2 Builtin.Arith.quotient

  let quotient_e = builtin ~ty:ty2i Builtin.Arith.quotient_e
  let quotient_t = builtin ~ty:ty2i Builtin.Arith.quotient_t
  let quotient_f = builtin ~ty:ty2i Builtin.Arith.quotient_f
  let remainder_e = builtin ~ty:ty2i Builtin.Arith.remainder_e
  let remainder_t = builtin ~ty:ty2i Builtin.Arith.remainder_t
  let remainder_f = builtin ~ty:ty2i Builtin.Arith.remainder_f

  let ty2o = Type.(forall ([bvar 0; bvar 0] ==> prop))

  let less = builtin ~ty:ty2o Builtin.Arith.less
  let lesseq = builtin ~ty:ty2o Builtin.Arith.lesseq
  let greater = builtin ~ty:ty2o Builtin.Arith.greater
  let greatereq = builtin ~ty:ty2o Builtin.Arith.greatereq

  (* hook that prints arithmetic expressions *)
  let pp_hook _depth pp_rec out t =
    let pp_surrounded buf t = match view t with
      | AppBuiltin (s, [_;_]) when Builtin.is_infix s ->
        Format.fprintf buf "(@[<hv>%a@])" pp_rec t
      | _ -> pp_rec buf t
    in
    match view t with
      | Var v when Type.equal (ty t) Type.int ->
        Format.fprintf out "I%d" (HVar.id v); true
      | Var v when Type.equal (ty t) Type.rat ->
        Format.fprintf out "Q%d" (HVar.id v); true
      | AppBuiltin (Builtin.Less, [_; a; b]) ->
        Format.fprintf out "%a < %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Lesseq, [_;a; b]) ->
        Format.fprintf out "%a ≤ %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Greater, [_;a; b]) ->
        Format.fprintf out "%a > %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Greatereq, [_;a; b]) ->
        Format.fprintf out "%a ≥ %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Sum, [_;a; b]) ->
        Format.fprintf out "%a + %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Difference, [_;a; b]) ->
        Format.fprintf out "%a - %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Product, [_;a; b]) ->
        Format.fprintf out "%a × %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Quotient, [_;a; b]) ->
        Format.fprintf out "%a / %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Quotient_e, [_;a; b]) ->
        Format.fprintf out "%a // %a" pp_surrounded a pp_surrounded b; true
      | AppBuiltin (Builtin.Uminus, [_;a]) ->
        Format.fprintf out "-%a" pp_surrounded a; true;
      | AppBuiltin (Builtin.Remainder_e, [_;a;b]) ->
        Format.fprintf out "%a mod %a" pp_surrounded a pp_surrounded b; true;
      | _ -> false  (* default *)

  let () = add_hook pp_hook
end



module DB = struct
  let is_closed = T.DB.closed
  let shift = T.DB.shift
  let eval = T.DB.eval
  let unshift = T.DB.unshift
  let unbound = T.DB.unbound
  let skolemize_loosely_bound ?(already_sk=IntMap.empty) t =
  let rec aux skolemized depth subt =
    match view subt with
    | Const _
    | Var _ ->  (subt, skolemized)
    | DB i ->
        if i >= depth then
          (match IntMap.find_opt (i-depth) skolemized with
          | (Some sk) -> (sk, skolemized)
          | None ->
             let new_sk = mk_fresh_skolem [] (ty subt) in
             let skolemized = IntMap.add (i-depth) new_sk skolemized in
             new_sk,skolemized)
          else subt, skolemized
    | Fun (v_ty,body) -> let b', s' = aux skolemized (depth+1) body in
                         fun_ v_ty b', s'
    | App (f, l) ->
       let hd', s' = aux skolemized depth f in
       let args, s'' = sk_args l s' depth  in
       app hd' args, s''
    | AppBuiltin (hd,l) -> let args, s' = sk_args l skolemized depth in
                           app_builtin ~ty:(ty subt) hd args, s'
  and sk_args l subst depth =
      List.fold_right (fun arg (acc, s) ->
        let arg', s_new = aux s depth arg in
        arg'::acc, s_new)
      l ([], subst)
  in
    aux already_sk 0 t

  let unskolemize sk_to_vars t =
    let rec aux depth subt =
      match Map.find_opt subt sk_to_vars  with
        Some i -> bvar ~ty:(ty subt) (depth+i)
        | None ->
          (match view subt with
          | Const _  | Var _  | DB _ -> subt
          | Fun (v_ty,body) -> fun_ v_ty (aux (depth+1) body)
          | App (f, l) -> let f' = aux depth f in
                          app f' (List.map (aux depth) l)
          | AppBuiltin (hd,l) -> app_builtin ~ty:(ty subt) hd (List.map (aux depth) l))
   in aux 0 t

  let rec map_vars_shift ?(depth=0) var_map t =
   match view t with
   | Const _  | DB _ -> t
   | Var _ -> (match Map.find_opt t var_map with
              | Some i -> bvar ~ty:(ty t) (i + depth)
              | None -> t)
   | Fun (v_ty,body) -> let depth = depth+1 in
                        fun_ v_ty (map_vars_shift ~depth var_map body)
   | App (f, l) -> let f' = map_vars_shift ~depth var_map f in
                   app f' (List.map (map_vars_shift ~depth var_map) l)
   | AppBuiltin (hd,l) -> app_builtin ~ty:(ty t) hd
                          (List.map (map_vars_shift ~depth var_map) l)

end

let debugf = pp

(** {2 TPTP} *)

module TPTP = struct
  let pp_depth ?hooks:_ depth out t =
    let depth = ref depth in
    (* recursive printing *)
    let rec pp_rec out t = match view t with
      | DB i ->
        Format.fprintf out "Y%d" (!depth - i - 1);
        (* print type of term *)
        if !print_all_types && not (Type.equal (ty t) Type.TPTP.i)
        then Format.fprintf out ":%a" (Type.TPTP.pp_depth !depth) (ty t)
      | AppBuiltin (b,[]) -> Builtin.TPTP.pp out b
      | AppBuiltin (b, ([t;u] | [_;t;u])) when Builtin.TPTP.is_infix b ->
        Format.fprintf out "(@[%a %a@ %a@])" pp_rec t Builtin.TPTP.pp b pp_rec u
      | AppBuiltin (b, l) when Builtin.TPTP.fixity b = Builtin.Infix_nary ->
        Format.fprintf out "(@[%a@])"
          (Util.pp_list ~sep:(Builtin.TPTP.to_string b) pp_rec) l
      | AppBuiltin (b,l) ->
        Format.fprintf out "(@[<hov2>%a@ %a@])" Builtin.TPTP.pp b (Util.pp_list pp_rec) l
      | Const s -> ID.pp_tstp out s
      | App (f, l) ->
        Format.fprintf out "@[<hov2>%a(@,%a)@]" pp_rec f
          (Util.pp_list ~sep:", " pp_rec) l
      | Fun _ ->
        let ty_args, bod = as_fun t in
        let vars = List.mapi (fun i ty -> i+ !depth, ty) ty_args in
        let pp_db out (i,ty) =
          Format.fprintf out "Y%d : %a" i Type.TPTP.pp ty
        in
        let old_d = !depth in
        depth := !depth + List.length ty_args;
        Format.fprintf out "(@[<hv2>^[@[%a@]]:@ %a@])"
          (Util.pp_list ~sep:"," pp_db) vars pp_rec bod;
        depth := old_d;
      | Var i ->
        Format.fprintf out "X%d" (HVar.id i);
        (* print type of term *)
        if !print_all_types && not (Type.equal (ty t) Type.TPTP.i) then (
          Format.fprintf out ":%a" (Type.TPTP.pp_depth !depth) (ty t);
        )
    in
    pp_rec out t

  let pp buf t = pp_depth 0 buf t
  let to_string = CCFormat.to_string pp
end

module ZF = struct
  let pp = T.pp_zf
  let to_string = CCFormat.to_string pp
end

let pp_in = function
  | Output_format.O_zf -> ZF.pp
  | Output_format.O_tptp -> TPTP.pp
  | Output_format.O_normal -> pp
  | Output_format.O_none -> CCFormat.silent

(** {2 Conversions} *)

module Conv = struct
  module PT = TypedSTerm

  type ctx = Type.Conv.ctx
  let create = Type.Conv.create

  let[@inline] var_to_simple_var ?(prefix="X") ctx v =
    Type.Conv.var_to_simple_var ~prefix ctx v

  let of_simple_term_exn ctx t =
    let tbl = PT.Var_tbl.create 8 in
    let depth = ref 0 in
    let rec aux t = match PT.view t with
      | PT.Var v ->
        (* is the variable bound? *)
        begin match PT.Var_tbl.get tbl v with
          | Some (i,ty) -> bvar ~ty (!depth - i - 1)
          | None ->
            var (Type.Conv.var_of_simple_term ctx v)
        end
      | PT.AppBuiltin (Builtin.Wildcard, []) ->
        (* fresh type variable *)
        var (Type.Conv.fresh_ty_var ctx)
      | PT.Const id ->
        let ty = Type.Conv.of_simple_term_exn ctx (PT.ty_exn t) in
        const ~ty id
      | PT.Bind (Binder.ForallTy, _, _)
      | PT.AppBuiltin (Builtin.Arrow, _)
      | PT.AppBuiltin (Builtin.Term,[])
      | PT.AppBuiltin (Builtin.Prop,[])
      | PT.AppBuiltin (Builtin.TType,[])
      | PT.AppBuiltin (Builtin.TyInt,[])
      | PT.AppBuiltin (Builtin.TyRat,[]) ->
        let t = Type.Conv.of_simple_term_exn ctx t in
        of_ty t
      | PT.App (f, l) ->
        let f = aux f in
        let l = List.map aux l in
        app f l
      | PT.AppBuiltin (b, l) ->
        let ty = Type.Conv.of_simple_term_exn ctx (PT.ty_exn t) in
        let l = List.map aux l in
        app_builtin ~ty b l
      | PT.Bind (Binder.Lambda, v, body) ->
        let ty_arg = Type.Conv.of_simple_term_exn ctx (Var.ty v) in
        PT.Var_tbl.add tbl v (!depth,ty_arg);
        incr depth;
        let body = aux body in
        decr depth;
        PT.Var_tbl.remove tbl v;
        fun_ ty_arg body
      | PT.Bind(b, v, body) when Binder.equal b Binder.Forall 
                                 || Binder.equal b Binder.Exists ->
        let b = if Binder.equal b Binder.Forall 
                then Builtin.ForallConst else Builtin.ExistsConst in
        let v = var (Type.Conv.var_of_simple_term ctx v) in
        let ty = Type.Conv.of_simple_term_exn ctx (PT.ty_exn body) in
        let body = aux body in
        app_builtin ~ty b [v; body]
      | PT.Meta _
      | PT.Record _
      | PT.Ite _
      | PT.Let _
      | PT.Match _
      | PT.Multiset _ 
      | _ -> raise (Type.Conv.Error t)
    in
    aux t

  let of_simple_term ctx t =
    try Some (of_simple_term_exn ctx t)
    with Type.Conv.Error _ -> None

  let to_simple_term ?(allow_free_db=false) ?(env=DBEnv.empty) ctx t =
    let module ST = TypedSTerm in
    let n = ref 0 in
    let rec aux_t env t =
      match view t with
        | Var i -> ST.var (aux_var i)
        | DB i ->
          begin match DBEnv.find env i with
            | Some v -> ST.var v
            | None when allow_free_db ->
              (* encode DB index *)
              ST.builtin ~ty:(aux_ty @@ ty t) (Builtin.Pseudo_de_bruijn i)
            | None ->
              Util.errorf ~where:"Term" "cannot find `Y%d`@ @[:in [%a]@]" i (DBEnv.pp Var.pp) env
          end
        | Const id -> ST.const ~ty:(aux_ty (ty t)) id
        | App (f,l) ->
          ST.app ~ty:(aux_ty (ty t))
            (aux_t env f) (List.map (aux_t env) l)
        | AppBuiltin (b,[v;body]) when Builtin.equal b Builtin.ForallConst ||
                                Builtin.equal b Builtin.ExistsConst ->
          let b = if Builtin.equal b Builtin.ForallConst 
                  then Binder.Forall else Binder.Exists in
          let v =
            (match view v with
            | Var i -> (aux_var i)
            | _ -> 
            let v = aux_t env v in
            raise (Type.Conv.Error v)) in
          ST.bind ~ty:(aux_ty (ty t)) b v (aux_t env body) 
        | AppBuiltin (b,l) ->
          ST.app_builtin ~ty:(aux_ty (ty t))
            b (List.map (aux_t env) l)
        | Fun (ty_arg, body) ->
          let v = Var.makef ~ty:(aux_ty ty_arg) "v_%d" (CCRef.incr_then_get n) in
          let body = aux_t (DBEnv.push env v) body in
          ST.bind Binder.Lambda ~ty:(aux_ty (ty t)) v body
    and aux_var v =
      Type.Conv.var_to_simple_var ~prefix:"X" ctx v
    and aux_ty ty =
      Type.Conv.to_simple_term ~env ctx ty
    in
    aux_t env t
end

let rebuild_rec t =
  let rec aux env t =
    let ty = Type.rebuild_rec ~env (ty t) in
    begin match view t with
      | Var v -> var (HVar.cast ~ty v)
      | DB i ->
        assert (if i >= 0 && i < List.length env then true
          else (Format.printf "%d not in %a@." i (CCFormat.Dump.list Type.pp) env; false));
        assert (if Type.equal ty (List.nth env i) then true
          else (Format.printf "@[%a@ has type %a@ but bound with type %a@]@."
              pp t Type.pp ty Type.pp (List.nth env i); false));
        bvar ~ty i
      | Const id -> const ~ty id
      | App (f, l) -> app (aux env f) (List.map (aux env) l)
      | AppBuiltin (b,l) -> app_builtin ~ty b (List.map (aux env) l)
      | Fun (ty_arg,bod) ->
        let ty_arg =
          Type.rebuild_rec ~env ty_arg
          |> Type.unsafe_eval_db env
        in
        fun_ ty_arg (aux (ty_arg::env) bod)
    end
  in
  aux [] t
