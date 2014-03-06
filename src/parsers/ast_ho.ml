
(*
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

(** {1 Very Simple AST}

AST that holds Horn Clauses and type declarations, nothing more. *)

open Logtk

module PT = PrologTerm

type term = PT.t

type t =
  | Clause of term * term list
  | Type of string * term

type location = ParseLocation.t

let pp buf t = match t with
  | Clause (head, []) ->
      Printf.bprintf buf "%a.\n" PT.pp head
  | Clause (head, body) ->
      Printf.bprintf buf "%a <-\n  %a.\n"
        PT.pp head (Util.pp_list ~sep:",\n  " PT.pp) body
  | Type (s, ty) ->
      Printf.bprintf buf "val %s : %a\n" s PT.pp ty

let to_string = Util.on_buffer pp
let fmt fmt s = Format.pp_print_string fmt (to_string s)

module Seq = struct
  let terms decl k = match decl with
    | Type (_, ty) -> k ty
    | Clause (head, l) ->
        k head; List.iter k l

  let vars decl =
    terms decl
      |> Sequence.flatMap PT.Seq.vars
end

module Term = struct
  let true_ = PT.TPTP.true_
  let false_ = PT.TPTP.false_
  let wildcard = PT.wildcard

  let var = PT.var
  let bind = PT.bind
  let const = PT.const
  let app = PT.app
  let record = PT.record
  let list_ = PT.list_

  let and_ ?loc l = app ?loc (const Symbol.Base.and_) [list_ l]
  let or_ ?loc l = app ?loc (const Symbol.Base.or_) [list_ l]
  let not_ ?loc a = app ?loc (const Symbol.Base.not_) [a]
  let equiv ?loc a b = app ?loc (const Symbol.Base.equiv) [list_ [a;b]]
  let xor ?loc a b = app ?loc (const Symbol.Base.xor) [list_ [a;b]]
  let imply ?loc a b = app ?loc (const Symbol.Base.imply) [a;b]
  let eq ?loc ?(ty=wildcard) a b = app ?loc (const Symbol.Base.eq) [ty; list_[a;b]]
  let neq ?loc ?(ty=wildcard) a b = app ?loc (const Symbol.Base.neq) [ty; list_[a;b]]
  let forall ?loc vars f = bind ?loc Symbol.Base.forall vars f
  let exists ?loc vars f = bind ?loc Symbol.Base.exists vars f

  let mk_fun_ty ?loc l ret =
    let rec mk l = match l with
      | [] -> ret
      | a::l' -> app ?loc (const Symbol.Base.arrow) [a; mk l']
    in mk l
  let tType = PT.TPTP.tType
  let forall_ty ?loc vars t = bind ?loc Symbol.Base.forall_ty vars t 
end
