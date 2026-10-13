open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange

module Kind = struct
  type t =
    | Web_data2
    | User_events
  [@@deriving sexp_of, compare, equal]

  let to_wire = function
    | Web_data2 -> "webData2"
    | User_events -> "userEvents"
  ;;

  let of_wire = function
    | "webData2" -> Some Web_data2
    | "userEvents" -> Some User_events
    | _ -> None
  ;;
end

module Request = struct
  type t =
    { subscribe : bool
    ; kind : Kind.t
    ; user : Address.t
    }
  [@@deriving sexp_of, equal]

  let of_json json =
    let open Yojson.Safe.Util in
    match json with
    | `Assoc _ ->
      let subscription = member "subscription" json in
      (match member "method" json, subscription with
       | `String (("subscribe" | "unsubscribe") as meth), `Assoc _ ->
         (match member "type" subscription, member "user" subscription with
          | `String kind, (`String _ as user) ->
            Option.map (Kind.of_wire kind) ~f:(fun kind ->
              { subscribe = String.equal meth "subscribe"
              ; kind
              ; user = Address.t_of_yojson user
              })
          | _ -> None)
       | _ -> None)
    | _ -> None
  ;;

  let to_json t =
    `Assoc
      [ "method", `String (if t.subscribe then "subscribe" else "unsubscribe")
      ; ( "subscription"
        , `Assoc
            [ "type", `String (Kind.to_wire t.kind); "user", Address.yojson_of_t t.user ]
        )
      ]
  ;;

  let response t = `Assoc [ "channel", `String "subscriptionResponse"; "data", to_json t ]
end

let web_data2 ex user =
  `Assoc
    [ "channel", `String "webData2"
    ; ( "data"
      , `Assoc
          [ ( "clearinghouseState"
            , Clearinghouse_state.yojson_of_t (Adapt.clearinghouse_state ex user) )
          ; ( "openOrders"
            , `List (List.map (Adapt.open_orders ex user) ~f:Open_order.yojson_of_t) )
          ; "serverTime", `Int (Exchange.now ex / 1_000_000)
          ; "user", Address.yojson_of_t user
          ] )
    ]
;;

let user_fills_event fills =
  `Assoc
    [ "channel", `String User_event.channel
    ; "data", User_event.yojson_of_t (Fills fills)
    ]
;;
