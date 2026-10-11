# NatSpec semantic checklist

The AST gate enforces presence. Reviewers must also verify meaning for every new
or changed public function, event and error.

- State who may call a mutation and which state changes.
- Name units explicitly: `ppm` uses a 1,000,000 denominator; `fp18` uses a
  1e18 denominator; token amounts are base units unless stated otherwise.
- State rounding direction for conversions, fee calculations and previews.
- For ordered arrays, identify the array they correspond to and require matching
  lengths in the description.
- For expected-current setters, document the caller-supplied current value, the
  proposed value, no-op rejection and stale-state mismatch behavior.
- For events, describe old/new values and whether amounts are gross, net or fee
  amounts.
- For errors, describe the violated invariant and give each argument its actual
  meaning; avoid generic templates such as “value produced by the view.”
- Use `Core`, `CoreDiamond`, `HelpersDiamond`, `CYGLD`, `basket asset`, and
  `treasury` according to the Phase 1 naming glossary.

Generated selector and ABI inventories do not replace semantic NatSpec. The
economic and admin surfaces remain hand-reviewed.
