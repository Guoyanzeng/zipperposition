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

(** {1 Bijective Serializer/Deserializer} *)

type 'a t

(** {2 Bijection description} *)

val unit_ : unit t
val string_ : string t
val int_ : int t
val bool_ : bool t
val float_ : float t

val list_ : 'a t -> 'a list t
val many : 'a t -> 'a list t  (* non empty *)
val opt : 'a t -> 'a option t
val pair : 'a t -> 'b t -> ('a * 'b) t
val triple : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
val quad : 'a t -> 'b t -> 'c t -> 'd t -> ('a * 'b * 'c * 'd) t
val quint : 'a t -> 'b t -> 'c t -> 'd t -> 'e t -> ('a * 'b * 'c * 'd * 'e) t
val guard : ('a -> bool) -> 'a t -> 'a t
  (** Validate values at encoding and decoding *)

val map : inject:('a -> 'b) -> extract:('b -> 'a) -> 'b t -> 'a t

type _ inject_branch =
  | BranchTo : 'b t * 'b -> 'a inject_branch
type _ extract_branch =
  | BranchFrom : 'b t * ('b -> 'a) -> 'a extract_branch

val switch : inject:('a -> string * 'a inject_branch) ->
             extract:(string -> 'a extract_branch) -> 'a t
  (** Discriminates unions based on the next character.
      [inject] must give a unique key for each branch, as well as mapping to another
      type (the argument of the algebraic constructor);
      [extract] retrieves which type to parse based on the key. *)

(** {2 Helpers} *)

val fix : ('a t lazy_t -> 'a t) -> 'a t
  (** Helper for recursive encodings. The parameter is the recursive bijection
      itself. It must be lazy. *)

val with_version : string -> 'a t -> 'a t
  (** Guards the values with a given version. Only values encoded with
      the same version will fit. *)

(** {2 Exceptions} *)

exception EncodingError of string
  (** Raised when encoding is impossible *)

exception DecodingError of string
  (** Raised when decoding is impossible *)

(** {2 Translations} *)

module TrBencode : sig
  val encode : bij:'a t -> 'a -> Bencode.t

  val decode : bij:'a t -> Bencode.t -> 'a

  val to_string : bij:'a t -> 'a -> string

  val of_string : bij:'a t -> string -> 'a

  val read : bij:'a t -> in_channel -> 'a
    (** Read a single value from the channel *)

  val read_stream : bij:'a t -> in_channel -> 'a Stream.t

  val write : bij:'a t -> out_channel -> 'a -> unit

  val write_stream : bij:'a t -> out_channel -> 'a Stream.t -> unit
end

