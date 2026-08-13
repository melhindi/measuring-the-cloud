# Smoke benchmarks

One short run, not a measurement. These exist so a plumbing smoke fits inside a
constrained time budget on providers that provision slowly: they verify that a
benchmark executes, produces parsable output and lands in the artifact tree,
and nothing more. Never use them for a comparison — a single 10-second
repetition has no dispersion and no warm-up worth the name.
