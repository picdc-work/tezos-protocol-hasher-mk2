(** A protocol dump produced by [octez-protocol-compiler -dump-only]. *)

type layout_case =
  | A  (** all 16 digits in the final Blake2b block (F >= 20) *)
  | B  (** some launch/thread digits in the next-to-last block (6 <= F < 20) *)
  | C  (** loop digits in the next-to-last block (F < 6) *)

type t = private {
  path : string;
  data : Bytes.t;  (** whole file *)
  length : int;  (** L *)
  digits_offset : int;  (** L - 20 *)
  final_block_length : int;  (** F = ((L - 1) mod 128) + 1 *)
  final_block_offset : int;  (** L - F *)
  layout_case : layout_case;
  base_offset : int;
      (** first block containing a nonce digit: [final_block_offset] in case
          A, [final_block_offset - 128] otherwise *)
  base_state : int64 array;
      (** Blake2b chaining value after every block before [base_offset] *)
}

val marker : string
(** ["(* Vanity nonce: "]. *)

val load : string -> (t, string) result
(** Read and validate; the error message names the file and the problem. *)

val with_nonce : t -> int64 -> Bytes.t
(** The full dump with its 16 digits replaced by the nonce. *)

val blocks_with_nonce : t -> int64 -> int64 array list
(** The block(s) from [base_offset] to the end (1 in case A, 2 otherwise),
    with the nonce written in. *)

val digest : t -> int64 -> string
(** Blake2b-256 of the dump with that nonce, from [base_state]. *)

val digest_full : t -> int64 -> string
(** Same, computed by digestif over the full dump (independent path). *)

val case_name : layout_case -> string
