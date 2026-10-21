# Sooth Protocol (SOOTH)

An immutable ERC-20 token with **1,000,000,000 SOOTH**, **18 decimals**, and
the full supply minted once to the immediate deployer in its constructor.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `src/SoothToken.sol:SoothToken` |
| Token name | `Sooth Protocol` |
| Token symbol | `SOOTH` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Initial recipient | Constructor `msg.sender` |
| Owner / administrator | None |
| Target chain, per assignment | Robinhood Chain, chain ID `4663` |

`INITIAL_SUPPLY` is the named constant for the full supply in base units.
Deploy the creation bytecode for `SoothToken` with no constructor arguments
and no native currency. The build artifact is
`out/SoothToken.sol/SoothToken.json`; it contains the ABI and creation bytecode.
No initialization transaction, library linking, external contract, oracle,
address configuration, or keeper is needed.

When the launch factory creates this contract, **the factory receives the
entire supply**, not the transaction's origin or the requester directly.
The constructor makes no external calls and works on an empty chain.
Deployment through a different intermediary gives that intermediary the
supply, so the launch operator must use the intended factory.

## Behavior and assumptions

SOOTH uses the vendored OpenZeppelin ERC-20 implementation without transfer
overrides. Transfers deliver exactly the requested amount. There are no
transfer taxes, burns, rebases, recipient hooks, transfer limits, or address
exemptions. Successful transfers and approvals return `true`; invalid
operations revert with ERC-6093 custom errors. Zero-amount transfers are
supported, but the zero address cannot receive tokens or be approved as a
spender. Transfers to the token contract itself are possible under standard
ERC-20 behavior and cannot be recovered.

Only holders and their approved spenders can move a holder's tokens. Finite
allowances decrease with `transferFrom`; `type(uint256).max` allowances are
treated as unlimited and do not decrease. `approve` replaces an allowance,
and approving zero revokes it. `transferFrom` requires allowance even when
the caller is the holder. Direct approvals emit `Approval`; allowance
consumption does not emit an additional `Approval` event, so integrations
should read `allowance` for its current value.

The token exposes no mint, burn, pause, blacklist, seizure, ownership,
upgrade, or rescue operation. The deployer has no special rights after
receiving the supply. It is not a proxy. There are no time, block-number,
randomness, gas-price, sequencer, or cross-chain assumptions in token logic.
Ordinary EVM transaction execution is sufficient.

## Build and test

Foundry and Solidity **0.8.26** are required. All Solidity dependencies and
their licenses are included as ordinary files under `lib/`; no install,
submodule, RPC, environment configuration, or network access is required
when the pinned compiler is already installed.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xecb2d3c3aa6de874c65853ce42096a04757c078e9a2c530fdd199d816270f626 forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, optimization at 200 runs, the Paris EVM
target, and `bytecode_hash = "none"`. Paris avoids requiring newer EVM
opcodes; the token needs no Cancun-specific features. Fuzz tests run 512
cases each. Stateful invariant tests run 128 sequences of 64 calls each,
with unexpected handler reverts treated as failures. Tests neither read
nor change environment variables, use RPC forks, nor depend on test order.
The seed above configures Foundry itself.

Tests cover metadata, the mint event, EOA and CREATE2 factory deployment,
exact launch distribution and claim transfers, ordinary transfers in both
directions through a pool-address analogue, allowance replacement and
revocation, finite and unlimited approvals, zero and self transfers,
overdraws, unauthorized spending, invalid recipients, atomic rollback of
failed transfers, and rejection of common administrative calls. Stateful
tests track an independent balance/allowance model across arbitrary
transfer and approval sequences and check conservation of the full supply.

The local factory/pool-address harness checks token transfer behavior; it
does not implement or simulate Uniswap swaps. The supplied protected checks
depend on separate launch infrastructure (`OwnerChecks`, `v4-core`,
`LaunchLiquidity`, and launch environment inputs) that is not present in
this project. End-to-end launch admission remains the independent
verifier's responsibility.

## Launch and operational responsibilities

The launch service prepares the manifest and deploys the token. This
project does not send transactions or include a launch manifest. According
to the assignment's launch policy, the factory distributes 10% to the
launch distributor, seeds the pool with 80%, and forwards the remaining
10% to the specified requester recipient. These allocations and the pool's
pricing/fees are the factory's responsibilities; the token constructor
does not allocate any part of the supply to additional recipients.

The operator must verify the chain, creation bytecode, constructor argument
list, metadata, `totalSupply`, and the initial factory balance before
distribution, then confirm the resulting transfers and publish verified
source. No token admin key or ongoing privileged operator exists. Holders
are responsible for recipient addresses and spender approvals. When
changing an existing nonzero allowance, revoke it first and confirm that
transaction before granting the replacement to reduce approval-race risk.
Unlimited approvals authorize the spender to use future balances as well.

### After launch

There are no settings or setters to configure. The external launch service
handles pool operation and distribution claims. Token transfers and
approvals work immediately. Lost keys, mistaken transfers, or tokens sent
to contracts unable to return them cannot be repaired by an administrator.

Local validation uses Foundry build, unit tests, fuzz tests, stateful
invariants, and formatting checks. Slither and Mythril are not part of
this project's validation. Tests do not replace the separate independent
security review before release.
