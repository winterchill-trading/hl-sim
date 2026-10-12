open! Core
open! Async
open! Hl_protocol
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Entry = struct
  type t =
    { time : int
    ; address : Address.t
    ; request : Exchange_request.t
    }
  [@@deriving sexp, equal, yojson]

  let to_line t = Yojson.Safe.to_string (yojson_of_t t)
  let of_line line = t_of_yojson (Yojson.Safe.from_string line)
end

type t = { writer : Writer.t }

let of_writer writer = { writer }

let open_file path =
  let%map writer = Writer.open_file ~append:true path in
  of_writer writer
;;

let write t entry =
  Writer.write t.writer (Entry.to_line entry);
  Writer.newline t.writer
;;

let flushed t = Writer.flushed t.writer
let close t = Writer.close t.writer

let load path =
  let%map lines = Reader.file_lines path in
  List.filter_map lines ~f:(fun line ->
    if String.is_empty (String.strip line) then None else Some (Entry.of_line line))
;;
