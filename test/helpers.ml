open! Core
open! Hl_protocol
open! Hl_sim

let addr n = Address.of_string (sprintf "0x%040x" n)
let px = Price.of_string
let sz = Size.of_string
let usd = Usd.of_string
let btc = Coin.of_string "BTC"
let owner_id a = Int.of_string ("0x" ^ String.drop_prefix (Address.to_string a) 2)

let print_result (r : Order_book.Result.t) =
  let fills =
    List.map r.fills ~f:(fun (f : Fill.t) ->
      [%sexp
        { tid = (f.tid : int)
        ; px = (f.px : Price.t)
        ; sz = (f.sz : Size.t)
        ; taker = ((Order_id.to_int_exn f.taker_oid, owner_id f.taker) : int * int)
        ; maker = ((Order_id.to_int_exn f.maker_oid, owner_id f.maker) : int * int)
        }])
  in
  print_s
    [%message
      ""
        ~status:(r.status : Order_book.Status.t)
        ~filled:(r.filled : Size.t)
        ~remaining:(r.remaining : Size.t)
        (fills : Sexp.t list)]
;;

module Book = struct
  type t =
    { book : Order_book.t
    ; mutable next_oid : int
    ; mutable next_tid : int
    ; mutable time : int
    }

  let create () = { book = Order_book.create btc; next_oid = 1; next_tid = 1; time = 0 }
  let book t = t.book

  let fresh t =
    let oid = Order_id.of_int t.next_oid in
    t.next_oid <- t.next_oid + 1;
    t.time <- t.time + 1;
    oid
  ;;

  let next_tid t () =
    let tid = t.next_tid in
    t.next_tid <- t.next_tid + 1;
    tid
  ;;

  let limit ?(quiet = false) ?(tif = Tif.Gtc) t ~owner side p s =
    let oid = fresh t in
    let r =
      Order_book.add_limit
        t.book
        ~oid
        ~owner:(addr owner)
        ~side
        ~px:(px p)
        ~sz:(sz s)
        ~tif
        ~time:t.time
        ~next_tid:(next_tid t)
        ()
    in
    if not quiet then print_result r;
    Order_book.invariant t.book;
    oid, r
  ;;

  let market ?(quiet = false) t ~owner side s ~slippage_bps =
    let oid = fresh t in
    let r =
      Order_book.market
        t.book
        ~oid
        ~owner:(addr owner)
        ~side
        ~sz:(sz s)
        ~slippage_bps
        ~time:t.time
        ~next_tid:(next_tid t)
        ()
    in
    if not quiet then print_result r;
    Order_book.invariant t.book;
    r
  ;;

  let print_l2 ?(n_levels = 10) t =
    let bids, asks = Order_book.l2 t.book ~n_levels in
    let show levels =
      List.map levels ~f:(fun (l : L2_book.Level.t) ->
        sprintf "%s x %s (%d)" (Price.to_string l.px) (Size.to_string l.sz) l.n)
    in
    print_s [%message "" ~bids:(show bids : string list) ~asks:(show asks : string list)]
  ;;
end
