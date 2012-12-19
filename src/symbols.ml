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

let attr_skolem = 0x1
let attr_split = 0x2

(** A symbol is a string, a unique ID, and some attributes *)
type symbol = (string * int * int)

(** A sort is just a symbol *)
type sort = symbol

let compare_symbols (_, t1,_) (_,t2,_) = t1 - t2

let hash_symbol (s, _, _) = Hashtbl.hash s

(** weak hash table for symbols *)
module HashSymbol = Weak.Make(
  struct
    type t = symbol
    let equal (s1,_,_) (s2,_,_) = s1 = s2
    let hash = hash_symbol
  end)

(** the global symbol table *)
let symb_table = HashSymbol.create 7

(** counter for symbols *)
let symb_count = ref 0

let mk_symbol ?(attrs=0) s =
  let s = (s, !symb_count, attrs) in
  let s' = HashSymbol.merge symb_table s in
  (if s' == s then incr symb_count);  (* update signature *)
  s'

let is_used s = HashSymbol.mem symb_table (s, 0, 0)

let name_symbol (s, _, _) = s

let tag_symbol (_, tag, _) = tag

let attrs_symbol (_, _, attr) = attr

module SHashtbl = Hashtbl.Make(
  struct
    type t = symbol
    let equal = (==)
    let hash s = hash_symbol s
  end)

module SMap = Map.Make(struct type t = symbol let compare = compare_symbols end)

module SSet = Set.Make(struct type t = symbol let compare = compare_symbols end)

(** A signature maps symbols to (sort, arity) *)
type signature = (int * sort) SMap.t

(* connectives *)
let true_symbol = mk_symbol "$true"
let false_symbol = mk_symbol "$false"
let eq_symbol = mk_symbol "="
let exists_symbol = mk_symbol "$$exists"
let forall_symbol = mk_symbol "$$forall"
let lambda_symbol = mk_symbol "$$lambda"
let not_symbol = mk_symbol"$$not"
let imply_symbol = mk_symbol "$$imply"
let and_symbol = mk_symbol "$$and"
let or_symbol = mk_symbol "$$or"

(* De Bruijn *)
let db_symbol = mk_symbol "$$db"
let succ_db_symbol = mk_symbol "$$s"

(* default sorts *)
let type_sort = mk_symbol "$tType"
let bool_sort = mk_symbol "$o"
let univ_sort = mk_symbol "$i"

let table =
  [true_symbol, bool_sort, 0;
   false_symbol, bool_sort, 0;
   eq_symbol, bool_sort, 2;
   exists_symbol, bool_sort, 1;
   forall_symbol, bool_sort, 1;
   lambda_symbol, univ_sort, 1;
   not_symbol, bool_sort, 1;
   imply_symbol, bool_sort, 2;
   and_symbol, bool_sort, 2;
   or_symbol, bool_sort, 2;
   db_symbol, univ_sort, 0;
   succ_db_symbol, univ_sort, 1;
   ]

(** default signature, containing predefined symbols with their arities and sorts *)
let base_signature =
  List.fold_left
    (fun signature (symb,sort,arity) -> SMap.add symb (arity, sort) signature)
    SMap.empty table

(** extract the list of symbols from the complete signature *)
let symbols_of_signature signature =
  SMap.fold (fun s _ l -> s :: l) signature []
