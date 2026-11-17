(** The name searched for in base58check strings: protocol hashes (the
    default) or addresses, described by a {!kind}. *)

type case_mode = Insensitive | Sensitive

type kind
(** What fixes how a name maps to hashes: prefix bytes, digest length, the
    fixed leading text, the number of free characters after it and the cap on
    the name length. [Target] holds data only and does not depend on
    [Address], which provides the address kinds. *)

val make_kind :
  fixed:string ->
  free:int ->
  prefix:string ->
  digest_length:int ->
  max_name:int ->
  noun:string ->
  strict:bool ->
  kind
(** [fixed] is the text every string starts with (["P"], ["tz1"]); [free] the
    number of characters after it that the name does not constrain (1 for a
    protocol hash, 0 for an address); [prefix] the bytes before the digest;
    [noun] is used in messages. [top64] holds [prefix] and the first digest
    bytes, so [prefix] has fewer than 8 bytes. With [strict], {!make} also
    rejects a name starting with [fixed] and a name no string of the kind can
    carry. Raises [Invalid_argument] if the prefix and digest cannot fill 64
    bits. *)

val protocol_hash : kind
(** [P] then any character; 2-byte prefix, 32-byte digest, names of 1 to 9
    characters. The default of {!make}. *)

val first_chars : kind -> string
(** The characters, in alphabet order, that some string of the kind can carry
    at the position of the name's first character. For an address kind this is
    a window of 24 consecutive values, its two edges possibly reachable only
    in part. *)

type t

val make : ?kind:kind -> ?case_mode:case_mode -> string -> (t, string) result
(** Without [kind] (protocol hash): 1 to 9 characters. [Insensitive]
    (default) lowercases the name and accepts characters with a base58 form
    in either case; [Sensitive] accepts only base58 characters. *)

val kind : t -> kind

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

val top64_of : kind -> string -> int64
(** The same for a kind: [prefix ‖ digest] truncated to 64 bits. Raises
    [Invalid_argument] if the digest does not have the kind's length. *)

val in_intervals : t -> int64 -> bool

val expected_rate : t -> float
(** Expected number of candidates per prefilter hit. *)
