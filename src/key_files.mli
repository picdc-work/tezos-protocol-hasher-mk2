(** Files that hold secrets: the key file of a match and the base-key file.
    Both are created with [O_CREAT | O_EXCL] and mode 0600. Error messages
    name paths and system errors, never contents. *)

type written =
  | New of string  (** the key file was created at this path *)
  | Existing of string
      (** a file at this path already holds exactly this key; nothing was
          written *)

val write_key :
  dir:string -> address:string -> Address.scheme -> secret:string -> (written, string) result
(** Writes the base58 secret on one line in [dir/<address>.key]. An existing
    file is never overwritten: if it holds the same key the result is
    [Existing], otherwise [Error]. [Error] too if the file cannot be written
    (a partly written file is removed). *)

val check_writable_dir : string -> (unit, string) result
(** Creates and removes an empty private file in the directory, so that an
    unwritable key directory is found before the search starts and not at
    the first match. *)

val parse_base_key : Curve_ref.curve -> string -> (Z.t, string) result
(** The content of a base-key file: 64 hexadecimal characters (surrounding
    whitespace ignored), a scalar in [\[1, n-1\]]. *)

val check_base_mode : int -> (unit, string) result
(** [Error] if the permission bits are wider than 0600. *)

val load_or_create_base : Curve_ref.curve -> string -> (Z.t, string) result
(** The base scalar of the file; if the file does not exist, creates it
    with a fresh scalar. An existing file with a mode wider than 0600, that
    is not a regular file, or with a bad content is refused. *)

val parse_seed_base : string -> (string, string) result
(** The content of a tz1 base-key file: 64 hexadecimal characters (surrounding
    whitespace ignored), the 32 bytes of the base; every value is valid. *)

val load_or_create_seed_base : string -> (string, string) result
(** As {!load_or_create_base} for the 32-byte base of the tz1 search: a fresh
    base from [/dev/urandom] when the file does not exist, same mode and
    content rules. *)
