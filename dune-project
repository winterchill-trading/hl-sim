(lang dune 3.0)
(name hl-sim)
(generate_opam_files true)
(license MIT)
(source (github winterchill-trading/hl-sim))
(package
 (name hl-sim)
 (synopsis "Hyperliquid exchange simulator")
 (depends ocaml dune core async ppx_jane ppx_yojson_conv yojson))
