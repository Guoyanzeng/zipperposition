(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)

(** Symbols and signature *)

type symbol_attribute = int

let attr_skolem = 1 lsl 0
let attr_split = 1 lsl 1
let attr_binder = 1 lsl 2
let attr_infix = 1 lsl 3
let attr_ac = 1 lsl 4

(** A symbol is a string, a unique ID, and some attributes *)
type symbol = {
  symb_name: string;
  mutable symb_id : int;
  mutable symb_attrs : int;
}

type sort =
  | Sort of symbol          (** Atomic sort *)
  | Fun of sort * sort list (** Function sort *)
  (** simple types *)

(** exception raised when sorts are mismatched *)
exception SortError of string

let compare_symbols s1 s2 = s1.symb_id - s2.symb_id

let hash_symbol s = Hash.hash_int s.symb_id

let hash_sort s = hash_symbol s

(** weak hash table for symbols *)
module HashSymbol = Hashcons.Make(
  struct
    type t = symbol
    let equal s1 s2 = String.compare s1.symb_name s2.symb_name = 0
    let hash s = Hash.hash_string s.symb_name
    let tag t s = (s.symb_id <- t; s)
  end)

(** counter for symbols *)
let symb_count = ref 0

let mk_symbol ?(attrs=0) s =
  let s = {
    symb_name = s;
    symb_id = 0;
    symb_attrs = attrs;
  } in
  HashSymbol.hashcons s

let is_used s = HashSymbol.mem {symb_name=s; symb_id=0; symb_attrs=0;}

let name_symbol s = s.symb_name

let tag_symbol s = s.symb_id

let attrs_symbol s = s.symb_attrs

(** does the symbol have this attribute? *)
let has_attr attr s = (s.symb_attrs land attr) <> 0

module SHashtbl = Hashtbl.Make(
  struct
    type t = symbol
    let equal = (==)
    let hash = hash_symbol
  end)

module SMap = Map.Make(struct type t = symbol let compare = compare_symbols end)

module SSet = Set.Make(struct type t = symbol let compare = compare_symbols end)

(* connectives *)
let true_symbol = mk_symbol "$true"
let false_symbol = mk_symbol "$false"
let eq_symbol = mk_symbol ~attrs:attr_infix "="
let exists_symbol = mk_symbol ~attrs:attr_binder "$$exists"
let forall_symbol = mk_symbol ~attrs:attr_binder "$$forall"
let lambda_symbol = mk_symbol ~attrs:attr_binder "$$lambda"
let not_symbol = mk_symbol "$$not"
let imply_symbol = mk_symbol ~attrs:attr_infix "$$imply"
let and_symbol = mk_symbol ~attrs:(attr_infix lor attr_ac) "$$and"
let or_symbol = mk_symbol ~attrs:(attr_infix lor attr_ac) "$$or"

(** {2 Magic symbols} *)

(** higher order curryfication symbol *)
let at_symbol = mk_symbol ~attrs:attr_infix "@"

(** pseudo symbol kept for locating bound vars in precedence. Bound
    vars are grouped in the precedence together w.r.t other symbols,
    but compare to each other by their index. *)
let db_symbol = mk_symbol "$$db_magic_cookie"

(** pseudo symbol for locating split symbols in precedence *)
let split_symbol = mk_symbol "$$split_magic_cookie"

(** {2 sorts} *)

let bool_symbol = mk_symbol "$o"
let type_symbol = mk_symbol "$tType"
let univ_symbol = mk_symbol "$i"

let rec compare_sort s1 s2 = match s1, s2 with
  | Sort a, Sort b -> compare_symbols a b
  | Fun (a, la), Fun (b, lb) ->
    let cmp = compare_sort a b in
    if cmp <> 0 then cmp else compare_sorts la lb
  | Sort _, Fun _ -> -1
  | Fun _, Sort _ -> 1
and compare_sorts l1 l2 = match l1, l2 with
  | [], [] -> 0
  | x1::l1', x2::l2' ->
    let cmp = compare_sort x1 x2 in
    if cmp <> 0 then cmp else compare_sorts l1' l2'
  | [], _ -> -1
  | _, [] -> 1

let rec hash_sort s = match s with
  | Sort s -> Hash.hash_string s.symb_name
  | Fun (s, l) -> hash_sorts (hash_sort s) l
and hash_sorts h l = match l with
  | [] -> h
  | x::l' -> hash_sorts (Hash.hash_int2 (hash_sort x) h) l'

(** weak hash table for sorts *)
module HashSort = Hashcons.Make(
  struct
    type t = sort
    let equal a b = compare_sort a b = 0
    let hash s = hash_sort s
    let tag t s = s  (* ignore tag *)
  end)

let mk_sort symb = HashSort.hashcons (Sort symb)

let (<==) s l = match l with
  | [] -> s  (* collapse 0-ary functions *)
  | _ -> HashSort.hashcons (Fun (s, l))

let (<=.) s1 s2 = s1 <== [s2]

let can_apply l args =
  try List.for_all2 (==) l args
  with Invalid_argument _ -> false

(** [s @@ args] applies the sort [s] to arguments [args]. Types must match *)
let (@@) s args = match s, args with
  | Sort _, [] -> s
  | Fun (s', l), _ when can_apply l args -> s'
  | _ -> raise (SortError "cannot apply sort")

let type_ = mk_sort type_symbol
let bool_ = mk_sort bool_symbol
let univ_ = mk_sort univ_symbol

(** Arity of a sort, ie nunber of arguments of the function, or 0 *)
let arity = function
  | Sort _ -> 0
  | Fun (_, l) -> List.length l

let table =
  [true_symbol, bool_;
   false_symbol, bool_;
   eq_symbol, bool_ <== [univ_; univ_];
   exists_symbol, bool_ <=. (bool_ <=. univ_);
   forall_symbol, bool_ <=. (bool_ <=. univ_);
   lambda_symbol, univ_ <=. (univ_ <=. univ_);
   not_symbol, bool_ <=. bool_;
   imply_symbol, bool_ <== [bool_; bool_];
   and_symbol, bool_ <== [bool_; bool_];
   or_symbol, bool_ <== [bool_; bool_];
   at_symbol, univ_ <== [univ_; univ_];   (* FIXME: this really ought to be polymorphic *)
   db_symbol, univ_;
   split_symbol, bool_;
   ]

(** A signature maps symbols to (sort, arity) *)
type signature = sort SMap.t

let empty_signature = SMap.empty

(** default signature, containing predefined symbols with their arities and sorts *)
let base_signature =
  List.fold_left
    (fun signature (symb,sort) -> SMap.add symb sort signature)
    empty_signature table

(** Set of base symbols *)
let base_symbols = List.fold_left (fun set (s, _) -> SSet.add s set) SSet.empty table

(** extract the list of symbols from the complete signature *)
let symbols_of_signature signature =
  SMap.fold (fun s _ l -> s :: l) signature []
