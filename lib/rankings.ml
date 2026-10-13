open! Core
open! Hl_protocol
module Exchange = Exchange_core_engine.Exchange

let ns_per_day = 86_400 * 1_000_000_000

module Window = struct
  type t =
    | Day
    | Week
    | Month
    | All_time
  [@@deriving sexp_of, enumerate]

  let to_wire = function
    | Day -> "day"
    | Week -> "week"
    | Month -> "month"
    | All_time -> "allTime"
  ;;

  let length_ns = function
    | Day -> Some ns_per_day
    | Week -> Some (7 * ns_per_day)
    | Month -> Some (30 * ns_per_day)
    | All_time -> None
  ;;
end

module Performance = struct
  type t =
    { pnl : Usd.t
    ; roi : float
    ; vlm : Usd.t
    }
  [@@deriving sexp_of]
end

module Row = struct
  type t =
    { address : Address.t
    ; account_value : Usd.t
    ; windows : (Window.t * Performance.t) list
    ; display_name : string option
    }
  [@@deriving sexp_of]
end

(* Cumulative figures at one time; differences between two of them give a window. *)
module Sample = struct
  type t =
    { time : int
    ; equity : Usd.t
    ; deposits : Usd.t
    ; volume : Usd.t
    }

  (* Before an account exists everything is zero. *)
  let origin =
    { time = Int.min_value; equity = Usd.zero; deposits = Usd.zero; volume = Usd.zero }
  ;;
end

type account =
  { mutable deposits : Usd.t
  ; mutable volume : Usd.t
  ; samples : Sample.t Queue.t (** oldest first *)
  }

type t =
  { sample_interval : int
  ; accounts : account Address.Table.t
  ; mutable last_sample : int option
  ; display_names : string Address.Table.t
  }

let retention = 31 * ns_per_day

let create ?(sample_interval = Time_ns.Span.minute) () =
  { sample_interval = Time_ns.Span.to_int_ns sample_interval
  ; accounts = Address.Table.create ()
  ; last_sample = None
  ; display_names = Address.Table.create ()
  }
;;

let account t address =
  Hashtbl.find_or_add t.accounts address ~default:(fun () ->
    { deposits = Usd.zero; volume = Usd.zero; samples = Queue.create () })
;;

let record_deposit t address usd =
  let a = account t address in
  a.deposits <- Usd.(a.deposits + usd)
;;

let set_display_name t address name = Hashtbl.set t.display_names ~key:address ~data:name

let record_volume t address usd =
  let a = account t address in
  a.volume <- Usd.(a.volume + usd)
;;

let equity ex address = (Exchange.account_view ex address).equity

let sample t ex =
  let now = Exchange.now ex in
  let due =
    match t.last_sample with
    | None -> true
    | Some last -> now - last >= t.sample_interval
  in
  if due
  then (
    t.last_sample <- Some now;
    Hashtbl.iteri t.accounts ~f:(fun ~key:address ~data:a ->
      Queue.enqueue
        a.samples
        { time = now
        ; equity = equity ex address
        ; deposits = a.deposits
        ; volume = a.volume
        };
      while
        Queue.length a.samples > 1 && now - (Queue.peek_exn a.samples).time > retention
      do
        ignore (Queue.dequeue_exn a.samples : Sample.t)
      done))
;;

(* The last sample at or before [time], or the origin. *)
let sample_at (a : account) time =
  let n = Queue.length a.samples in
  let rec search lo hi =
    (* invariant: samples [0, lo) are at or before [time], [hi, n) after it *)
    if lo >= hi
    then lo
    else (
      let mid = (lo + hi) / 2 in
      if (Queue.get a.samples mid).time <= time
      then search (mid + 1) hi
      else search lo mid)
  in
  match search 0 n with
  | 0 -> Sample.origin
  | i -> Queue.get a.samples (i - 1)
;;

let performance (now : Sample.t) (start : Sample.t) : Performance.t =
  let deposits = Usd.(now.deposits - start.deposits) in
  let pnl = Usd.(now.equity - start.equity - deposits) in
  let base = Usd.(start.equity + deposits) in
  { pnl
  ; roi = (if Usd.is_positive base then Usd.to_float pnl /. Usd.to_float base else 0.)
  ; vlm = Usd.(now.volume - start.volume)
  }
;;

let rows t ex =
  let now_time = Exchange.now ex in
  Hashtbl.to_alist t.accounts
  |> List.filter ~f:(fun (_, a) -> not (Usd.is_zero a.deposits))
  |> List.map ~f:(fun (address, a) ->
    let now : Sample.t =
      { time = now_time
      ; equity = equity ex address
      ; deposits = a.deposits
      ; volume = a.volume
      }
    in
    { Row.address
    ; account_value = now.equity
    ; windows =
        List.map Window.all ~f:(fun w ->
          let start =
            match Window.length_ns w with
            | None -> Sample.origin
            | Some len -> sample_at a (now_time - len)
          in
          w, performance now start)
    ; display_name = Hashtbl.find t.display_names address
    })
  |> List.sort ~compare:(fun (a : Row.t) b ->
    match Usd.compare b.account_value a.account_value with
    | 0 -> Address.compare a.address b.address
    | c -> c)
;;

(* Plain decimal notation with up to ten decimals, as the stats host sends. *)
let decimal x =
  let s = sprintf "%.10f" x in
  let s = String.rstrip s ~drop:(Char.equal '0') in
  if String.is_suffix s ~suffix:"." then s ^ "0" else s
;;

let to_json rows =
  let usd u = `String (Usd.to_string u) in
  `Assoc
    [ ( "leaderboardRows"
      , `List
          (List.map rows ~f:(fun (r : Row.t) ->
             `Assoc
               [ "ethAddress", Address.yojson_of_t r.address
               ; "accountValue", usd r.account_value
               ; ( "windowPerformances"
                 , `List
                     (List.map r.windows ~f:(fun (w, (p : Performance.t)) ->
                        `List
                          [ `String (Window.to_wire w)
                          ; `Assoc
                              [ "pnl", usd p.pnl
                              ; "roi", `String (decimal p.roi)
                              ; "vlm", usd p.vlm
                              ]
                          ])) )
               ; "prize", `Int 0
               ; ( "displayName"
                 , Option.value_map r.display_name ~default:`Null ~f:(fun n -> `String n)
                 )
               ])) )
    ]
;;

(* The windows of the [portfolio] response, in Hyperliquid's order. The simulator trades
   only perps, so the [perp] windows are the same as the others. *)
let portfolio_windows : (string * Window.t) list =
  [ "day", Day
  ; "week", Week
  ; "month", Month
  ; "allTime", All_time
  ; "perpDay", Day
  ; "perpWeek", Week
  ; "perpMonth", Month
  ; "perpAllTime", All_time
  ]
;;

let empty_series =
  `Assoc
    [ "accountValueHistory", `List []
    ; "pnlHistory", `List []
    ; "vlm", `String (Usd.to_string Usd.zero)
    ]
;;

(* Points are the window's samples, then the current state, in milliseconds. PnL is
   relative to the window's start, as in [performance]. *)
let window_series t ex address window =
  match Hashtbl.find t.accounts address with
  | None -> empty_series
  | Some a ->
    let now_time = Exchange.now ex in
    let since =
      match Window.length_ns window with
      | None -> Int.min_value
      | Some len -> now_time - len
    in
    let start =
      match Window.length_ns window with
      | None -> Sample.origin
      | Some len -> sample_at a (now_time - len)
    in
    let now : Sample.t =
      { time = now_time
      ; equity = equity ex address
      ; deposits = a.deposits
      ; volume = a.volume
      }
    in
    let samples =
      Queue.to_list a.samples
      |> List.filter ~f:(fun (s : Sample.t) -> s.time >= since && s.time < now_time)
    in
    let points = samples @ [ now ] in
    let usd u = `String (Usd.to_string u) in
    let ms (s : Sample.t) = `Int (s.time / 1_000_000) in
    let pnl (s : Sample.t) =
      Usd.(s.equity - s.deposits - (start.equity - start.deposits))
    in
    `Assoc
      [ ( "accountValueHistory"
        , `List (List.map points ~f:(fun s -> `List [ ms s; usd s.equity ])) )
      ; "pnlHistory", `List (List.map points ~f:(fun s -> `List [ ms s; usd (pnl s) ]))
      ; "vlm", usd (performance now start).vlm
      ]
;;

let portfolio t ex address =
  `List
    (List.map portfolio_windows ~f:(fun (name, window) ->
       `List [ `String name; window_series t ex address window ]))
;;
