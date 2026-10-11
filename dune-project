(lang dune 3.17)

(name hl-sim)

(generate_opam_files true)

(license MIT)

(source
 (github winterchill-trading/hl-sim))

(package
 (name hl-sim)
 (synopsis "Hyperliquid exchange simulator")
 (depends ocaml dune core hl-protocol ppx_jane))
