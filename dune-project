(lang dune 3.17)

(name hl-sim)

(generate_opam_files true)

(license MIT)

(source
 (github winterchill-trading/hl-sim))

(package
 (name hl-sim)
 (synopsis "Hyperliquid exchange simulator")
 (depends
  ocaml
  dune
  core
  core_unix
  async
  cohttp-async
  http
  async_websocket
  uri
  yojson
  fixed-decimal
  exchange-core
  exchange-core-engine
  hl-protocol
  order-book
  market-data
  price-anchor
  hl-client
  binance-client
  ppx_jane
  ppx_yojson_conv))
