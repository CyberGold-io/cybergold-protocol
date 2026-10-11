# Deployed Core live coordinator runtime

`deployed-core-live-coordinator.hex` retains the exact runtime installed at
`0x60d0784A3f4dD93759e6e2bCE48F59FaA2fa2D84`, compiled from Protocol commit
`31a675b5e6a68268b53590825295dda1b00117bc` and installed by transaction
`0x4343ed28e767c2d71fca9278637603d21cf4d9a24cef55fb3c68c491a06ae9af`.

The runtime is 15,067 bytes with keccak256
`0x0282a85c0081e7384a120fc9ea2253a5a6b231f8169c07d5939f0540ef0df98f`.
It was independently read at Mainnet block 26,074,122 (block hash
`0xf13e8893f1ff32dff384aced25dcad06b53a2d6332775ce62a0b248a46ca920f`).

Historical migration tests use these frozen bytes instead of rewriting metadata
on the current compiler output. This preserves the deployed mandatory-initializer
behavior while the current coordinator source permits storage-neutral cuts.
