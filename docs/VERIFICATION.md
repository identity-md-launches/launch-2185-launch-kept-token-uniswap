# Verification record

## Token and hook launch — 2026-10-18

Launch scope: `src/KeptToken.sol:KeptToken` and `src/KeptHook.sol:KeptHook`, chain 4663, paired
with IMD, with the constructor arguments in [README.md](../README.md). All commands below simulate
or read; nothing was signed or broadcast. The local CREATE2 probe and fork fixtures are tests, not
deployment instructions.

### Build and offline suite

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x1cacf04b210f5bc3adc0aa32053cf59f520528175c4bad608c637a003db5baa6 forge test --offline
```

Unchanged project configuration (Solidity 0.8.26, Cancun, via IR, optimizer 200,
`bytecode_hash = "none"`): **build passes; 157 tests pass, zero fail, one skipped** (the opt-in
fork suite, offline). No environment variable, network call, scratch file or file under
`.imd/reads` is needed by the committed offline suite. Build lint emits advisory warnings only.
Slither and Mythril were not run. `forge fmt --check` passes on every changed Solidity file.

New or changed coverage for this launch:

- `KeptHookTest` and `KeptHookTokenFirstTest` (both currency orders): the fee is
  `ceil(gross IMD * feeNow / 10_000)` on every checked swap, never more than the IMD leg, and at
  least one wei whenever the pool moves IMD; the audit's dust cases (4 wei at 20%, 99/100/101 wei
  and exact-output 98 wei at 1%); the window starts at the first IMD-moving swap, not at
  initialization, and an empty-pool swap does not start it; constructor argument order; a second
  initialization reverts; 256 fuzz runs per fuzz test with the seed above. Every checked swap now
  also asserts that `openedAt` moves exactly when the manager's `Swap` event carries a nonzero IMD
  amount.
- `KeptHookOpeningTest` and `KeptHookOpeningTokenFirstTest` (revision finding 277d240e): a 1-wei
  exact-input IMD swap on the empty pool is charged its wei but leaves `openedAt` at zero; after
  thirty minutes a seed and a 1,000 IMD buy still pay 20% (200 IMD) and open the window then. The
  same wei on a seeded pool is charged without opening it; a 2-wei swap, which the pool fills one
  wei of, opens it.
- `KeptTokenTest`: no constructor arguments, 10^27 supply to the deployer, transfer, allowance,
  infinite allowance, no mint/burn/owner/pause/fee entry points, supply conservation.
- `KeptHookLaunchTest`: on an empty chain id 4663 (no code at the PoolManager, IMD or vault
  addresses), deploys the token with no arguments and the hook with
  `(0x8366a39c…, IMD, token, 0x3152f9cb…, factory)` via a local CREATE2 probe at a salt mined for
  `0x20cc`; an unmined address is refused; constructors reject value; both runtimes fit EIP-170 and
  contain no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE` or `CREATE2` (PUSH data skipped).

| Built contract | Creation bytes | Runtime bytes |
| --- | ---: | ---: |
| `KeptHook` | 11,839 | 10,864 |
| `KeptToken` | 1,133 | 1,025 |

Neither has external library links; every library function the hook calls is `internal`.

### Robinhood fork rehearsal

```sh
forge test --match-contract RobinhoodForkTest --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number 92064204 -vv
```

Run with the fuzz seed above: **2 passed, 0 failed, 0 skipped** on 2026-10-18 (re-run after the
revision below; the earlier pass of this launch was at block `92,017,157`). RPC chain ID `4663`.
Pinned block `92,064,204`, hash
`0x1e2ec9ae65b26c6871b8d10dc2fa1f81223c5cce4258cabd23c5e749e57ca1ed`, timestamp `1792356444`.
The public RPC answered "historical state is not available" for a block a few thousand behind its
head, so a rerun must pin a block read moments before it starts.

Dependencies read at that block:

| Dependency | Address | Runtime Keccak-256 | Read/behaviour checked |
| --- | --- | --- | --- |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626` | initialize, modifyLiquidity, four swaps, ERC-6909 mint/burn/take |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` | `0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2` | `symbol() = "IMD"`, `decimals() = 18`; transfers, allowances, `fundReferee` pull |
| KeptVault | `0x3152f9cbf64d0c1ac24ea7e101db3e4d8da86896` | `0xf9d85b0c7ed81de3425f21426ed06d5e3c1c88c21670c0cf2ae11e6bf8bc2f43` | `imd()` is the launch's IMD, `owner()` is `0xd3336a7c…`; `refereeFund()` grows by exactly the swept fee |

The live vault's runtime is 21,509 bytes with the hash above, the same size and hash this record
lists for the vault launch's build of `src/KeptVault.sol`, and its `refereeFund()` read 0 at the
head on 2026-10-18.

`test_hookTradesAndFundsTheRefereeOnTheLivePoolManager` deploys a local `KeptToken` and the hook at
a `0x20cc` address with the launch's argument order (live PoolManager, live IMD, the token, the
deployed vault, the test as factory). A non-factory account cannot initialize the pool; the factory
can, and that does not start the window. Before any liquidity exists, a 1-wei IMD buy is charged
its wei and still does not start the window (revision finding 277d240e). Liquidity is seeded
afterwards; thirty minutes later the first 1 IMD buy is charged exactly 0.2 IMD and starts the
window; a 4-wei buy is charged 1 wei; after another thirty minutes a 1 KEPT sell pays the steady
1% of its IMD output. A third-party `sweep()` moves the whole collected amount into the deployed
vault's Referee Fund, and the hook's pending claims return to zero. Gas reported by Forge:
2,575,152.

`test_checkBuysARealOracleRequest` is the vault launch's rehearsal against the live Intake,
retained unchanged (gas 1,185,872 at this block).

Funding is synthetic (`deal`); nothing was broadcast. A fork proves contract-call compatibility
with the live bytecode, not the factory's own deployment path. The public RPC may prune this
block; reruns may need an archive endpoint or a newly recorded block.

## Vault launch — 2026-10-18 (archived)

Launch scope: only `src/KeptVault.sol:KeptVault`, chain 4663, with the seven constructor
arguments in [launches/vault-2172.adaptation.md](launches/vault-2172.adaptation.md). The vault is
now live at `0x3152f9cbf64d0c1ac24ea7e101db3e4d8da86896`. Test counts and fork results below are
those recorded for that launch, before the token and hook changes above.

### Build and offline suite

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0xbff2f5cdfbaaad68fc59cf2f26a34756028433dee47aad2e0b9e9d93b549cf38 forge test --offline
```

Using the unchanged project configuration (Solidity 0.8.26, Cancun, via IR, optimizer 200,
`bytecode_hash = "none"`): **build passes; 98 tests pass, zero fail**. The opt-in Robinhood
fork suite reports one setup skip offline. No environment variable, network call, scratch file
or file under `.imd/reads` is needed by the committed offline suite. The seed above is supplied
for reproducibility, not required for the tests to run.

Coverage includes the vault lifecycle, the original callback/signature guards and conformance
vector, the production oracle signature, hook accounting on a local PoolManager in both currency
orders, 256 cases per fuzz test, and the configured 128 invariant runs × 128 calls. The handler's
smoke test still reaches both a payout and a burn after the beneficiary permission change.

New tests cover the reproduced audit cases, deadline and signature-time boundaries for all three
snapshot templates, retained GitHub grace, beneficiary-only attempts, default/explicit price caps,
repricing through the timelock, atomic rollback and rebates. They retain a characterization of
the expressly unsupported shrinking-token case; its passing test is **not** a claim of solvency
support for such tokens. See [launches/vault-2172.adaptation.md](launches/vault-2172.adaptation.md)
for every disposition of that launch.

`KeptVaultLaunchTest` deploys the exact constructor inputs via a local CREATE2 probe on an empty
chain, without initialization. It verifies that the specified owner, not the factory or origin,
controls the vault, rejects constructor ETH, and scans the runtime while skipping PUSH data.
No DELEGATECALL, CALLCODE, SELFDESTRUCT, CREATE or CREATE2 occurs as a runtime opcode.

| Built vault measurement | Bytes |
| --- | ---: |
| Creation bytecode | 23,325 |
| Init code including seven constructor words | 23,549 |
| Runtime | 21,509 |
| EIP-170 runtime limit | 24,576 |

No external library links remain. The constructor ABI is nonpayable and unchanged.
Build lint emits advisory warnings; compilation and tests succeed. Slither and Mythril were
not run. The protected floor itself needs deployment-step inputs; the committed local tests
rehearse its relevant constructor/ownership/size/opcode checks without inventing those inputs.

### Robinhood fork rehearsal

```sh
forge test --match-contract RobinhoodForkTest --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number 91883318 -vv
```

Also run with the fuzz seed above: **2 passed, 0 failed, 0 skipped** on 2026-10-18.
RPC chain ID was `4663`. The pinned block is `91,883,318`, hash
`0x7db98f2508908b8cd3bf073ff0eeea6f1a2e383b2c28577809937c5b11b28c50`,
timestamp `2026-10-18T15:41:17Z`.

Dependencies read at that block:

| Dependency | Address | Runtime bytes | Read/behaviour checked |
| --- | --- | ---: | --- |
| Intake v1 | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` | 6,568 | `priceOf(action, IMD) = 500000000000000000`; real request and event |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` | 15,448 | `symbol() = "IMD"`, `decimals() = 18`; transfers and allowances |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | 24,009 | `protocolFeeController() = 0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`; existing swap/sweep rehearsal |

Observed runtime Keccak-256 hashes:

- Intake: `0xf82308e5e8a54560a70885f3eb16b6692c4b2f6442ed4c51c4b9a9df3d1114cc`
- IMD: `0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2`
- PoolManager: `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626`

`test_checkBuysARealOracleRequest` deploys a local vault with the launch owner and protocol inputs,
creates a synthetic pledge, and pays exactly 0.5 IMD through the live Intake bytecode. It checks
zero leftover allowance and the emitted request ID, requester, action, complete body, callback
target/selector, asset and amount. Gas reported by Forge: 1,185,678.

`test_hookTradesAndFundsTheRefereeOnTheLivePoolManager` preserves the project's existing
integration rehearsal: in the local fork only, a test token/hook/pool is created, buy/sell swaps
run on the live PoolManager bytecode, and sweeping fees funds the vault by exactly that amount.
Gas reported: 2,139,438. This test does not put a token, hook, pool or initialization call in the
contracts-only launch.

Funding is synthetic (`deal`); no oracle request was submitted to the live network. A fork proves
contract-call compatibility, not control-plane delivery or future RPC availability. The public
RPC may prune this block; future reruns may need an archive endpoint or a newly recorded block.

### Oracle question preflight

On 2026-10-18, extracted the four representative bodies directly from the compiled vault's
`previewQuestion`, using the existing fixture's release/page inputs, the pinned live Intake as
the deployed-contract target, and live IMD `totalSupply()` with threshold 1 for the value sample.
All four free screenings returned **HTTP 200, `judged: true`, `blockers: []`**. ContractDeployed
also received a nonblocking wording suggestion; no question template was changed for it.
The exact bodies, projected requests and full responses are in
[ORACLE_PREFLIGHT.json](ORACLE_PREFLIGHT.json).

The free endpoint accepts a shorter input: `question`, `panelSize`, `evidence`, `chainId` and
`answerType`. Posting an entire onchain body first returned HTTP 400 for the extra
`v/window/quorum/validForSeconds` keys. Retrying with that documented projection succeeded.
The service's drafted response uses a 24-hour default window; the actual vault still sends its
unchanged one-hour window. This checks the question wording, not exact-byte acceptance of every
onchain field, nor the truth of the requested milestone. No paid quote, panel or transaction was
opened. See the [protocol's oracle-body documentation](https://imd.fun/docs/#oracle-body).

### Interface checks

`node --check web/src/main.js` passes. A scratch Node check executes the actual milestone-state
function and beneficiary gate with distinct creator/beneficiary accounts, tests proof versus
delivery labels, and compares the regenerated ABI with the compiled vault (including both
overloads and `PriceAboveLimit`). All pass. No website dependencies were installed or changed;
the old `dist/` bundle is outside this contracts-only launch and was not rebuilt or published.

## Existing production-signature evidence

`test/RealAttestation.t.sol` recovers the pinned oracle signer
`0x5598aa9146215bc13eb26f2c692ad1461fd32982` from Robinhood request
`2cbdce1f-1eb9-4a87-ba4c-2ec8ce244392` (attested 2026-10-08T21:41Z) using KEPT's own
`OracleAttestation.hashStruct`. That request has `agreed` 139 below `quorum` 140, settled by a
chain rerun. This existing behaviour is retained for chain evidence; panel evidence still needs
quorum agreement. The canonical digest/signature conformance tests also remain unchanged except
that a full pledge round trip requests from its beneficiary.

## Historical record

The imported project recorded fork passes on 2026-10-09 at blocks 83,978,104, 84,048,406 and
84,292,071, and earlier free question checks/unpaid quotes. Those are historical claims, not the
current rehearsal above. Its earlier review fixes (team-restricted checks, in-flight signer
snapshots, separate refunds, budget reporting, input validation and hook approvals) remain,
with checks now further restricted to the beneficiary as the reproduced audit requires.
