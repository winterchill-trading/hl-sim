open! Core
open! Hl_protocol
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

type t =
  | Update_leverage of
      { asset : Asset.t
      ; is_cross : bool
      ; leverage : int
      }
  | Schedule_cancel of { time : int option }
  | Batch_modify of { modifies : Modify_request.t list }
[@@deriving sexp, compare, equal]

module Update_leverage_wire = struct
  type t =
    { asset : Asset.t
    ; is_cross : bool [@key "isCross"]
    ; leverage : int
    }
  [@@deriving yojson] [@@yojson.allow_extra_fields]
end

module Schedule_cancel_wire = struct
  type t = { time : int option [@default None] [@yojson_drop_if Option.is_none] }
  [@@deriving yojson] [@@yojson.allow_extra_fields]
end

module Batch_modify_wire = struct
  type t = { modifies : Modify_request.t list }
  [@@deriving yojson] [@@yojson.allow_extra_fields]
end

let type_tag = function
  | Update_leverage _ -> "updateLeverage"
  | Schedule_cancel _ -> "scheduleCancel"
  | Batch_modify _ -> "batchModify"
;;

let yojson_of_t t =
  let body =
    match t with
    | Update_leverage { asset; is_cross; leverage } ->
      Update_leverage_wire.yojson_of_t { asset; is_cross; leverage }
    | Schedule_cancel { time } -> Schedule_cancel_wire.yojson_of_t { time }
    | Batch_modify { modifies } -> Batch_modify_wire.yojson_of_t { modifies }
  in
  Json.with_tag body ~key:"type" ~value:(type_tag t)
;;

let of_action_json json =
  match Json.member json ~key:"type" with
  | Some (`String "updateLeverage") ->
    let { Update_leverage_wire.asset; is_cross; leverage } =
      Update_leverage_wire.t_of_yojson json
    in
    Some (Update_leverage { asset; is_cross; leverage })
  | Some (`String "scheduleCancel") ->
    let { Schedule_cancel_wire.time } = Schedule_cancel_wire.t_of_yojson json in
    Some (Schedule_cancel { time })
  | Some (`String "batchModify") ->
    let { Batch_modify_wire.modifies } = Batch_modify_wire.t_of_yojson json in
    Some (Batch_modify { modifies })
  | _ -> None
;;

let t_of_yojson json =
  match of_action_json json with
  | Some t -> t
  | None -> Json.error "Extra_action: unsupported action type" json
;;
