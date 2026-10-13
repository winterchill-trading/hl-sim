open! Core
open! Hl_protocol

module Agent = struct
  type t =
    { name : string option
    ; address : Address.t
    ; valid_until : int option
    }
  [@@deriving sexp_of]

  (* Far enough ahead that clients treat an agent without expiry as permanent. *)
  let no_expiry = 4_102_444_800_000

  let to_json t =
    `Assoc
      [ "name", `String (Option.value t.name ~default:"")
      ; "address", Address.yojson_of_t t.address
      ; "validUntil", `Int (Option.value t.valid_until ~default:no_expiry)
      ]
  ;;
end

(* ["copy valid_until 1700000000000"] is the agent "copy" expiring at that time. *)
let split_name name =
  match String.substr_index name ~pattern:" valid_until " with
  | None -> name, None
  | Some i ->
    let base = String.prefix name i in
    let rest = String.drop_prefix name (i + String.length " valid_until ") in
    (match Int.of_string_opt (String.strip rest) with
     | Some ms -> base, Some ms
     | None -> name, None)
;;

let max_named_agents = 3
let max_builders = 10
let max_approved_fee = 1000
let nonces_kept = 100
let ms_per_day = 86_400_000

type t =
  { agents : Agent.t list Address.Table.t (** by owner *)
  ; owners : Address.t Address.Table.t (** by agent *)
  ; nonces : Int.Set.t Address.Table.t (** by signer *)
  ; builders : int Address.Map.t Address.Table.t (** by user *)
  }

let create () =
  { agents = Address.Table.create ()
  ; owners = Address.Table.create ()
  ; nonces = Address.Table.create ()
  ; builders = Address.Table.create ()
  }
;;

let find_agent t agent =
  Option.bind (Hashtbl.find t.owners agent) ~f:(fun owner ->
    Hashtbl.find t.agents owner
    |> Option.bind ~f:(List.find ~f:(fun (a : Agent.t) -> Address.equal a.address agent))
    |> Option.map ~f:(fun a -> owner, a))
;;

let owner ?now_ms t agent =
  match find_agent t agent with
  | Some (owner, { valid_until = Some until; _ }) ->
    (match now_ms with
     | Some now when now >= until -> None
     | _ -> Some owner)
  | Some (owner, _) -> Some owner
  | None -> None
;;

let agents t user =
  Hashtbl.find t.agents user
  |> Option.value ~default:[]
  |> List.sort ~compare:(fun (a : Agent.t) b -> [%compare: string option] a.name b.name)
;;

let approve_agent t ~user ~agent ~name =
  (* An empty name is the unnamed agent, as the SDK signs it. *)
  let name, valid_until =
    match Option.filter name ~f:(fun n -> not (String.is_empty n)) with
    | None -> None, None
    | Some n ->
      let base, until = split_name n in
      Some base, until
  in
  let current = Hashtbl.find t.agents user |> Option.value ~default:[] in
  let replaced, kept =
    List.partition_tf current ~f:(fun (a : Agent.t) ->
      [%equal: string option] a.name name)
  in
  let named = List.count kept ~f:(fun a -> Option.is_some a.name) in
  if Address.equal agent user
  then (* sim wording *) Error "Cannot approve the account itself as its agent."
  else if Option.exists (owner t agent) ~f:(fun o -> not (Address.equal o user))
          || Hashtbl.mem t.agents agent
  then (* sim wording *) Error "Agent address is already in use."
  else if Option.is_some name && named >= max_named_agents
  then (* sim wording *) Error "Too many named agents: at most 3 per account."
  else (
    List.iter replaced ~f:(fun a -> Hashtbl.remove t.owners a.address);
    (* A re-approval of the same address keeps a single entry. *)
    let kept = List.filter kept ~f:(fun a -> not (Address.equal a.address agent)) in
    Hashtbl.set t.agents ~key:user ~data:({ name; address = agent; valid_until } :: kept);
    Hashtbl.set t.owners ~key:agent ~data:user;
    Ok ())
;;

let use_nonce t ~signer ~nonce ~now_ms =
  let used = Hashtbl.find t.nonces signer |> Option.value ~default:Int.Set.empty in
  if nonce <= now_ms - (2 * ms_per_day) || nonce >= now_ms + ms_per_day
  then
    (* sim wording *)
    Error (sprintf "Invalid nonce: %d is outside the time window." nonce)
  else if Set.mem used nonce
  then (* sim wording *) Error (sprintf "Invalid nonce: %d was already used." nonce)
  else if Set.length used >= nonces_kept && nonce < Set.min_elt_exn used
  then (* sim wording *) Error (sprintf "Invalid nonce: %d is too low." nonce)
  else (
    let used = Set.add used nonce in
    let used = if Set.length used > nonces_kept then Set.remove_index used 0 else used in
    Hashtbl.set t.nonces ~key:signer ~data:used;
    Ok ())
;;

let max_builder_fee t ~user ~builder =
  Hashtbl.find t.builders user
  |> Option.bind ~f:(fun m -> Map.find m builder)
  |> Option.value ~default:0
;;

let approve_builder_fee t ~user ~builder ~tenths_bps =
  let current = Hashtbl.find t.builders user |> Option.value ~default:Address.Map.empty in
  if tenths_bps > max_approved_fee
  then (* sim wording *) Error "Max fee rate is above the 1% limit."
  else if tenths_bps > 0
          && (not (Map.mem current builder))
          && Map.length current >= max_builders
  then (* sim wording *) Error "Too many builder fee approvals: at most 10 per account."
  else (
    let updated =
      if tenths_bps = 0
      then Map.remove current builder
      else Map.set current ~key:builder ~data:tenths_bps
    in
    Hashtbl.set t.builders ~key:user ~data:updated;
    Ok ())
;;
