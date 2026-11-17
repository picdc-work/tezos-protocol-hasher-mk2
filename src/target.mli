(** The name searched for in protocol hashes. *)

type case_mode = Insensitive | Sensitive

type t

val make : ?case_mode:case_mode -> string -> (t, string) result
(** 1 to 9 characters. [Insensitive] (default) lowercases the name and
    accepts characters with a base58 form in either case; [Sensitive]
    accepts only base58 characters. *)

val name : t -> string

val case_mode : t -> case_mode

val matches : t -> string -> bool
(** Exact rule on a full protocol hash, from its 3rd character:
    insensitive [lowercase hash.[2..2+len) = name], sensitive exact. *)

val intervals : t -> (int64 * int64) array
(** Sorted, disjoint intervals on [top64]; every matching hash has its
    [top64] in one of them. *)

val top64 : string -> int64
(** [(0x02aa ‖ digest ‖ checksum) >> 240] = [0x02aa << 48 | digest[0..5]]. *)

val in_intervals : t -> int64 -> bool

val expected_rate : t -> float
(** Expected number of candidates per prefilter hit. *)
