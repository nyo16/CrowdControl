# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # The nested sandboxd release is a separate Mix project, so it is formatted
  # through its own .formatter.exs rather than by widening the globs above.
  # `mix format` at the root therefore covers it; so does `mix format` inside it.
  subdirectories: ["sandboxd"]
]
