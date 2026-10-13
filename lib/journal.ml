open! Core
open! Async
open! Hl_protocol
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Entry = struct
  type t =
    { time : int
    ; address : Address.t
    ; request : Exchange_request.t
    ; builder : Builder.t option [@default None] [@yojson_drop_if Option.is_none]
    }
  [@@deriving sexp, equal, yojson]

  let to_line t = Yojson.Safe.to_string (yojson_of_t t)
  let of_line line = t_of_yojson (Yojson.Safe.from_string line)
end

module User_entry = struct
  type t =
    { time : int
    ; address : Address.t
    ; user_action : User_action.t [@key "userAction"]
    ; signature : Json.t option [@default None] [@yojson_drop_if Option.is_none]
    }
  [@@deriving sexp, equal, yojson]
end

module Extra_entry = struct
  type t =
    { time : int
    ; address : Address.t
    ; extra_action : Extra_action.t [@key "l1Action"]
    }
  [@@deriving sexp, equal, yojson]
end

module Record = struct
  type t =
    | Request of Entry.t
    | User_action of User_entry.t
    | Extra of Extra_entry.t
  [@@deriving sexp_of, equal]

  let to_json = function
    | Request e -> Entry.yojson_of_t e
    | User_action e -> User_entry.yojson_of_t e
    | Extra e -> Extra_entry.yojson_of_t e
  ;;

  let to_line t = Yojson.Safe.to_string (to_json t)

  let of_line line =
    let json = Yojson.Safe.from_string line in
    match Json.member json ~key:"userAction", Json.member json ~key:"l1Action" with
    | Some _, _ -> User_action (User_entry.t_of_yojson json)
    | None, Some _ -> Extra (Extra_entry.t_of_yojson json)
    | None, None -> Request (Entry.t_of_yojson json)
  ;;
end

type t = { writer : Writer.t }

let of_writer writer = { writer }

let open_file path =
  let%map writer = Writer.open_file ~append:true path in
  of_writer writer
;;

let write_line t line =
  Writer.write t.writer line;
  Writer.newline t.writer
;;

let write t entry = write_line t (Entry.to_line entry)
let write_record t record = write_line t (Record.to_line record)
let flushed t = Writer.flushed t.writer
let close t = Writer.close t.writer

let load path =
  let%map lines = Reader.file_lines path in
  List.filter_map lines ~f:(fun line ->
    if String.is_empty (String.strip line) then None else Some (Record.of_line line))
;;
