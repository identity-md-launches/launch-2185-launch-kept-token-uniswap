# KEPT

**Promises the swarm enforces.** A team locks its tokens behind public milestones. At each
deadline the IMD swarm checks the milestone and signs a verdict onchain. Kept: the tokens
unlock to the team. Broken: they are burned.

Built on the IMD protocol for Robinhood Chain (4663). Every check is paid in IMD to the swarm.

`KeptVault` is live on Robinhood Chain at `0x3152f9cbf64d0c1ac24ea7e101db3e4d8da86896`
(its launch record is under [docs/launches](docs/launches)). This assignment launches
**`src/KeptToken.sol:KeptToken` and `src/KeptHook.sol:KeptHook`** through IMD's Uniswap v4 hook
factory on chain 4663, paired with IMD. The factory deploys both in one transaction, mines the
hook's CREATE2 address so it carries permission bits `0x20cc`, initializes the KEPT/IMD pool at
LP fee 12500 and tick spacing 60, and holds the pool's liquidity. Nothing here is deployed,
signed or broadcast by this repository.

| Contract | Constructor arguments, in order |
| --- | --- |
| `KeptToken` | none; mints 1,000,000,000 KEPT (10^27 minor units) to its deployer, the factory |
| `KeptHook` | `$poolManager` (`IPoolManager`); IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`; `$token`; KeptVault `0x3152f9cbf64d0c1ac24ea7e101db3e4d8da86896`; `$factory` |

The hook has no owner, proxy or upgrade path, so no `$owner` argument exists. `$factory` is used
for one thing: only that account may initialize the pool. The manifest belongs to the following
launch step. See [ADAPTATION.md](ADAPTATION.md) for every change and audit disposition and
[docs/VERIFICATION.md](docs/VERIFICATION.md) for checks and the fork rehearsal.

### The hook's fee

- **What**: a fee on the gross IMD leg of every swap in the KEPT/IMD pool, never on KEPT:
  20% at opening, decaying linearly to 1% over 30 minutes, then 1% forever. The fee is
  rounded up, so any swap that moves IMD pays at least one wei.
- **When the clock starts**: at the first swap that moves IMD through the pool, not at pool
  initialization, so liquidity seeded after initialization still opens at 20%. Until then
  `feeNow()` is 20%. A swap the pool fills nothing of does not start it: on the empty pool, or
  1 wei of IMD whose whole amount is the rounded-up fee, the fee is still charged but the window
  stays closed, so nobody can burn the window down before liquidity exists.
- **Where it goes**: the fee is kept in IMD as PoolManager ERC-6909 claims owned by the hook.
  Anyone can call `sweep()`, which redeems them and deposits the IMD into the vault's Referee
  Fund (`fundReferee`), which rebates the oracle check of every milestone the oracle answers
  kept. The brief keeps the fee in IMD; it is not converted to ETH and no ETH is ever held.
- **What the Referee Fund is**: a public subsidy for oracle checks of kept milestones, held by
  the live `KeptVault`. The rebate is not tied to the pledge's value or the question's
  difficulty: anyone can create a pledge on 1 wei of any ERC-20 with a milestone that is already
  true, buy its check, and have the price rebated, so over time the fund pays the oracle for
  checks of whatever pledges are created, not only genuine KEPT teams'. The fund's only outflow
  is that rebate, paid at whatever price the vault's Intake quotes. The hook has no owner, but
  the vault's owner (`0xd3336a7c8a7d8814c437196abb16c4fe7aa7b016`, an externally owned account
  today) may replace the Intake, action and signer after a public seven-day notice, with no cap
  on a rebate, so the fees the hook collects are custodied under that key with that notice. See
  [ADAPTATION.md](ADAPTATION.md) for why this is documented rather than changed.
- **Callbacks**: `beforeInitialize` (factory-only, single pool, pins the pair, fee and
  spacing), `beforeSwap` + `beforeSwapReturnDelta` (fee on the IMD-specified legs: exact-in buys
  and exact-out sells) and `afterSwap` + `afterSwapReturnDelta` (fee on the IMD-unspecified
  legs: exact-out buys and exact-in sells). All five were in the brief; none were added.
- **The LP fee** stays the static 12500 (1.25%); the hook never overrides it.

- Full design: [docs/SPEC.md](docs/SPEC.md)
- Protocol research and addresses: [docs/research.md](docs/research.md)

## Contracts

| Contract | What it does |
| --- | --- |
| `KeptVault` | Holds locked tokens per pledge, buys oracle checks from the IMD Intake, verifies signed verdicts, pays kept tranches and burns broken ones. Open to any project. |
| `KeptToken` | KEPT, fixed 1,000,000,000 supply, plain ERC-20. |
| `KeptHook` | Uniswap v4 hook on the KEPT/IMD pool. Takes 1% of the IMD leg (20% at the first filled trade, decaying over 30 minutes), rounded up, and sweeps it into the vault's Referee Fund, which refunds the check of every milestone the oracle answers kept. |

Milestones use four templates so every question the swarm gets is precise:
`GithubRelease`, `PageContains`, `ContractDeployed`, `ValueAtLeast`.

Only a pledge's **beneficiary** can buy its three check attempts. Anyone can fund it, clear a
stale check, settle, or return the completed pledge's unused budget to its creator.
`check(id, index)` caps payment at `DEFAULT_MAX_PRICE = 500000000000000000` (0.5 IMD).
`check(id, index, maxPrice)` explicitly accepts another ceiling in IMD atomic units; it still
pays only the live quote. A higher quote reverts without spending budget or an attempt.
`checkOpen` has matching two- and three-argument forms; `funded` includes the price ceiling.

Page and chain templates are snapshots: ask early enough for the oracle to **sign by the
deadline**. A timely, unexpired signature may be delivered later. Their grace period does not
permit a new check or a signature issued after the deadline. GitHub release checks can still
be requested during the three-day grace period because their question explicitly requires
publication by the deadline. Early success remains final: these templates do not prove that
a page, deployment or value persists through the deadline. Missing or delayed oracle evidence
can still cause a burn; a paid check does not guarantee delivery or a refund.

## Supported tokens and trust

Use plain ERC-20s whose vault balance changes only through exact transfers. **Do not deposit
rebasing, balance-decaying, confiscatable or transfer-restricted tokens**, including tokens
whose administrator can later introduce these behaviours. Deposit taxes are rejected by an
exact balance-delta check, but that check cannot detect future balance shrinkage or freezes.
Metadata or a successful deposit is not evidence of compatibility.

KEPT accounts in nominal units and pools custody by token. If an unsupported token shrinks
the vault's balance, early settlements can consume the remaining backing and the last tranche
can become unpayable. Its IMD budget then remains locked because budget refunds require all
milestones to settle. There is no pro-rata loss allocation or rescue withdrawal. This is a
documented restriction, not an onchain detector of every incompatible ERC-20.

The owner may replace the Intake, action and signer after a public seven-day delay. Existing
pledges cannot exit during that notice, and an owner-selected signer can approve later checks.
In-flight requests retain their original Intake and signer. Panel changes affect future pledges;
ownership can be transferred or renounced. The owner and IMD's request-to-verdict pairing remain
trust assumptions. The pinned v1 Intake supports `request`; failed requests use the existing
one-day timeout, without a v2 failure callback.

## Build and test

Solidity 0.8.26, Cancun, via IR, optimizer 200, `bytecode_hash = "none"`. Dependencies are
vendored under `lib/` (no submodules, network, FFI or filesystem permissions needed).

```sh
forge build
forge test
```

The suite covers the full pledge lifecycle, every callback guard, the IMD oracle
conformance vector (KEPT verifies the protocol's real signature), the hook's exact rounded-up fee
in all four swap modes on a real local PoolManager in both currency orders, the opening window
and dust cases, the launch token's supply and transfers, a local rehearsal of the launch shape
(empty chain, CREATE2 at a mined `0x20cc` address, opcode scan), and stateful invariants proving
locked tokens and IMD are always accounted for. The Robinhood fork suite is opt-in:

```sh
forge test --match-contract RobinhoodForkTest --fork-url https://rpc.mainnet.chain.robinhood.com
```

## Provenance

`src/OracleAttestation.sol` is the protocol's canonical consumer, copied unchanged from
AskOracle (launch 976). `KeptHook` fee math and `src/libraries/SpecifiedAmount.sol` come
from the accepted imdDRONE hook (launch 909). Both are MIT.
