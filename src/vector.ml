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

(** Growable, mutable vector *)

(** a vector of 'a. *)
type 'a t = {
  mutable size : int;
  mutable capacity : int;
  mutable vec : 'a array;
}

let create i =
  assert (i >= 0);
  { size = 0;
    capacity = i;
    vec = if i = 0 then [||] else Array.create i (Obj.magic None);
  }

(** resize the underlying array so that it can contains the
    given number of elements *)
let resize v newcapacity =
  if newcapacity <= v.capacity
    then ()  (* already big enough *)
    else begin
      assert (newcapacity >= v.size);
      let new_vec = Array.create newcapacity (Obj.magic None) in
      Array.blit v.vec 0 new_vec 0 v.size;
      v.vec <- new_vec;
      v.capacity <- newcapacity
    end

let clear v =
  v.size <- 0;
  if v.capacity > 1000  (* shrink if too large *)
    then (v.capacity <- 10;
          v.vec <- Array.create 10 (Obj.magic None))

let is_empty v = v.size = 0

let push v x =
  (if v.capacity = v.size
    then resize v (2 * v.capacity));
  v.vec.(v.size) <- x;
  v.size <- v.size + 1

(** add all elements of b to a *)
let append a b =
  resize a (a.size + b.size);
  Array.blit b.vec 0 a.vec a.size b.size;
  a.size <- a.size + b.size

let append_array a b =
  resize a (a.size + Array.length b);
  Array.blit b 0 a.vec a.size (Array.length b);
  a.size <- a.size + Array.length b

let pop v =
  (if v.size = 0 then failwith "Vector.pop on empty vector");
  v.size <- v.size - 1;
  let x = v.vec.(v.size) in
  x

let copy v =
  let v' = create v.size in
  Array.blit v.vec 0 v'.vec 0 v.size;
  v'.size <- v.size;
  v'

let shrink v n =
  if n > v.size then failwith "cannot shrink to bigger size" else v.size <- n

let member ?(cmp=(=)) v x =
  let n = v.size in
  let rec check i =
    if i = n then false
    else if cmp x v.vec.(i) then true
    else check (i+1)
  in check 0

let sort ?(cmp=compare) v =
  (* copy array (to avoid junk in it), then sort the array *)
  let a = Array.sub v.vec 0 v.size in
  Array.fast_sort cmp a;
  v.vec <- a

let uniq_sort ?(cmp=compare) v =
  sort ~cmp v;
  let n = v.size in
  (* traverse to remove duplicates. i= current index,
     j=current append index, j<=i. new_size is the size
     the vector will have after removing duplicates. *)
  let rec traverse prev i j =
    if i >= n then () (* done traversing *)
    else if cmp prev v.vec.(i) = 0
      then (v.size <- v.size - 1; traverse prev (i+1) j) (* duplicate, remove it *)
      else (v.vec.(j) <- v.vec.(i); traverse v.vec.(i) (i+1) (j+1)) (* keep it *)
  in
  if v.size > 0
    then traverse v.vec.(0) 1 1 (* start at 1, to get the first element in hand *)

let iter v k =
  for i = 0 to v.size -1 do
    k v.vec.(i)
  done

let iteri v k =
  for i = 0 to v.size -1 do
    k i v.vec.(i)
  done

let map v f =
  let v' = create v.size in
  for i = 0 to v.size - 1 do
    push v' (f v.vec.(i));
  done;
  v'

let filter v f =
  let v' = create v.size in
  for i = 0 to v.size - 1 do
    if f v.vec.(i) then push v' v.vec.(i);
  done;
  v'

let fold v acc f =
  let acc = ref acc in
  for i = 0 to v.size - 1 do
    acc := f !acc v.vec.(i);
  done;
  !acc

let exists v p =
  let n = v.size in
  let rec check i =
    if i = n then false
    else if p v.vec.(i) then true
    else check (i+1)
  in check 0

let for_all v p =
  let n = v.size in
  let rec check i =
    if i = n then true
    else if not (p v.vec.(i)) then false
    else check (i+1)
  in check 0

let find v p =
  let n = v.size in
  let rec check i =
    if i = n then raise Not_found
    else if p v.vec.(i) then v.vec.(i)
    else check (i+1)
  in check 0

let get v i =
  (if i < 0 || i >= v.size then failwith "wrong index for vector");
  v.vec.(i)

let set v i x =
  (if i < 0 || i >= v.size then failwith "wrong index for vector");
  v.vec.(i) <- x

let size v = v.size

let from_array a =
  let c = Array.length a in
  let v = create c in
  Array.blit a 0 v.vec 0 c;
  v.size <- c;
  v

let from_list l =
  let v = create 10 in
  List.iter (push v) l;
  v

let to_array v =
  Array.sub v.vec 0 v.size

let get_array v = v.vec

let to_list v =
  let l = ref [] in
  for i = 0 to v.size - 1 do
    l := get v i :: !l;
  done;
  List.rev !l
