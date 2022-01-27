{ name = "coroutine-transducers"
, dependencies = [
  "console",
  "either",
  "foldable-traversable",
  "freet",
  "functors",
  "newtype",
  "parallel",
  "prelude",
  "tailrec",
  "transformers",
  "tuples",
  "aff",
  "coroutines",
  "effect",
  "maybe",
  "psci-support"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs", "test/**/*.purs" ]
}
