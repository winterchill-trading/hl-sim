(** Websocket client for tests (async_websocket only implements framing). *)

open! Core
open! Async

(** Connects to [ws://127.0.0.1:port/ws]; returns the pipes of text messages. *)
val connect : int -> (string Pipe.Reader.t * string Pipe.Writer.t) Deferred.t

(** Prints the next message, or [<eof>]. *)
val receive : string Pipe.Reader.t -> unit Deferred.t
