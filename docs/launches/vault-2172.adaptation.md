# KEPT vault launch adaptation

## Scope and constructor

This is a contracts-only launch of `src/KeptVault.sol:KeptVault` on Robinhood Chain (4663).
`KeptToken`, `KeptHook`, their libraries, pools and initialization are outside this launch.
No transaction was signed or broadcast, and no launch manifest is supplied by this step.

The existing nonpayable constructor already fits the factory: seven static arguments,
`address,address,address,bytes32,address,uint16,uint16`, no external calls and no code-presence
requirements. It takes the owner explicitly rather than deriving it from the factory or
transaction origin. Its arguments remain, in order:

1. `$owner` → `0xd3336a7c8a7d8814c437196abb16c4fe7aa7b016`
2. Intake v1 `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56`
3. IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`
4. Action `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`
5. Signer `0x5598aa9146215bc13eb26f2c692ad1461fd32982`
6. Panel size `9`
7. Quorum `7`

No constructor adaptation was necessary. Build configuration, remappings, dependencies, lockfiles
and unrelated production contracts remain unchanged. No dependencies were installed.

## Imported findings and reproductions

All four behavioural reports reproduced before changing the production source. Both informational
reports describe real properties of the original project; neither requires removing a capability
or replacing a supplied address. No imported behavioural finding was dismissed as irreproducible.

### 402848657cada9ef2d4adad191e08553d9859d1913ff1cc1a9a7274c6b11c421 — deadline

The supplied `Proof_402848657cad.t.sol` failed on the original code because the beneficiary
received 100 tokens for a contract snapshot signed two days after its deadline.

Changed `src/KeptVault.sol`: the three snapshot templates (`PageContains`, `ContractDeployed`,
`ValueAtLeast`) now close new checks at their deadline, inclusive, and refuse attestations with
`issuedAt > deadline`. Checking only the request time would leave a request queued before the
deadline vulnerable to late processing. `checkOpen` uses the same cutoff.

The GitHub template still allows checks during grace: its unchanged question explicitly pins
publication time. A timely, unexpired snapshot signature can arrive after the deadline. Requests
and signatures for snapshot templates must be made early enough to account for oracle latency.
The existing early-success semantics remain: snapshots do not prove continuous validity or
state at the exact deadline. This is now explicit in the README, specification and interface.
No absolute block window was introduced; the contract has no cross-chain timestamp-to-block
mapping and cannot safely infer one from Robinhood's `block.number`.

Tests in `test/KeptVaultAudit.t.sol` cover every affected template, both check entry points,
deadline boundaries, a queued request answered late, burning after refusal, an on-time signature
delivered later under 200,000 gas, and GitHub's retained grace period.

### fb69143f635a904755e24aa1e2a071bb212a3e375ec06713b78954a8839c60e6 — attempts

The supplied `Proof_fb69143f635a.t.sol` failed on the original code with `AttemptsExhausted`
when a separate beneficiary tried to prove its release after the creator used all three checks.

Changed `src/KeptVault.sol`: only the pledge's beneficiary can spend attempts and budget on
checks. A creator who is also the beneficiary still works. Permissionless funding, stale clearing,
settlement and refund-to-creator behaviour remain unchanged. The audit regression attempts the
creator's attack three times and then proves and settles from the beneficiary; it also checks
that an unauthorized retry cannot clear a stale request as a side effect.

Updated `test/KeptVault.t.sol`, `test/OracleConformance.t.sol` and `test/VaultInvariant.t.sol`
to request from the actual beneficiary. Their lifecycle, conformance and accounting assertions
are retained, including the invariant handler's payout/burn smoke test.

### dab3a05f3869676d227db3dac94d857b6d7fa0273a108c8da940cf8eb66185f8 — price

A scratch reproduction replaced the Intake after seven days, quoted 100 IMD and confirmed that
the original two-argument check spent the entire 100 IMD budget.

Changed `src/KeptVault.sol`: `check(id,index,maxPrice)` enforces a caller-selected ceiling before
spending budget, recording an attempt or granting allowance. It pays the actual quote, not the
ceiling. The existing `check(id,index)` selector remains usable with
`DEFAULT_MAX_PRICE = 500000000000000000`, the brief's 0.5 IMD price, not an invented fee.
There is no unlimited legacy entry point. `PriceAboveLimit(price,maxPrice)` explains refusals.
Both `checkOpen` variants include the corresponding ceiling in their `funded` result.

The audit regression tests reprice the existing Intake and replace it through the timelock,
fuzz prices above/below/equal to an explicit ceiling, test zero quotes, verify rollback of stale
clearing on refusal, check zero remaining allowance, and rebate exactly the price paid.

### 74f963a8ddc3dacf95910a87adaa19b217ebe31547abe556df5a59e7f77c53f3 — shrinking tokens

Reproduced two exact deposits of 100, a vault balance reduced to 180, one settlement of 100,
then the final transfer reverting with only 80 available. The last pledge still had `open = 1`
and its 10 IMD budget could not be withdrawn.

Disposition: the finding explicitly offers **documented refusal of such tokens** instead of
pro-rata accounting. The README, `docs/SPEC.md` and pledge-creation interface now explicitly
exclude rebasing, balance-decaying, confiscatable and transfer-restricted tokens and explain
the shared-balance loss and blocked-budget consequence. The original specification already
excluded rebasing tokens; this expands and makes that restriction prominent. An ERC-20 interface
cannot prove the absence of future confiscation or upgrades. Exact deposit checks are not a
runtime detector for that risk. No solvency fix, allowlist, new admin power, rescue or changed
loss-allocation economics is claimed.

`test/KeptVaultTokenCompatibility.t.sol` retains the unsupported-case reproduction and a
supported-token case with two pledges, a release, a burn and independent budget refunds.

### ca8117ff21af06ccc70fb3e24664638a12957257238bc9ec2c4050da6954c9b3 — protocol control

Confirmed the owner can change Intake/action/signer after seven days, change future panels,
and transfer or renounce ownership. Existing tests exercise the delay, old in-flight bindings
and acceptance of a newly selected signer. These intended settings remain. The README,
specification and interface now state that locked pledges cannot exit during notice and the
owner's choice of signer is a trust assumption, including for checks on existing pledges.

KeptVault continues to use `request()` with the exact v1 Intake the brief names. The v2 preference
does not justify silently changing a pinned deployment input. V1 failure/no-answer recovery
remains the existing one-day timeout; the fee and attempt are spent.

### 718ac5652b66357cb9fd8b866f9144a06db6cb8bd7295435fac2dd8dd761c4db — scope/evidence

Read the vault, oracle consumer, questions, Intake interface and their tests against the supplied
protocol reference. The canonical 15-field attestation, type hash, domain and callback signature
remain unchanged. Preserved the existing chain-evidence rerun exception for `agreed < quorum`,
which is covered by the supplied canonical Solidity comments and the project's real-signature
test; panel evidence still needs quorum agreement.

Added `test/KeptVaultLaunch.t.sol` to rehearse the exact constructor arguments via local CREATE2
on an empty chain, verify owner isolation from factory/origin, reject constructor value, check
init/runtime size and scan executable opcodes (skipping PUSH data). The vault runtime also must
not contain CREATE or CREATE2. This is a local probe, not a call to the live launch factory.

Updated `test/fork/Robinhood.t.sol` to use the launch owner, assert live dependency code and IMD
metadata, and check the Intake event's action, asset and amount as well as body/callback. Its
existing PoolManager simulation remains a compatibility rehearsal only: it does not add a token,
hook or pool to the launch. Current results and question preflights are in `docs/VERIFICATION.md`.
The separate hook/token contracts were not changed or represented as newly audited.

## Other files changed and validation

- `README.md`: exact launch handoff, price APIs, deadline semantics, token restrictions and trust
  assumptions, all required by the scope or findings above.
- `docs/SPEC.md`: aligns lifecycle and supported-token/trust descriptions with those dispositions.
- `web/src/main.js`: beneficiary-only controls, snapshot deadline/delivery wording, capped-price
  wording and token/protocol-control disclosures, to avoid offering actions the fixed vault rejects.
- `web/src/abi/KeptVault.json`: regenerated from the built vault for the new overloads, constant
  and error. Existing selectors and events are retained.
- `docs/VERIFICATION.md` and its question-preflight evidence: reproducible current build, test,
  live-read and fork results, with the limits of each check.

Foundry tests use the required seed
`0xbff2f5cdfbaaad68fc59cf2f26a34756028433dee47aad2e0b9e9d93b549cf38`.
The committed suite remains offline; RPC and free HTTP preflights are opt-in checks. No scratch
test or `.imd/reads` dependency is needed by a delivered file. Source-only interface edits are
syntax/behaviour checked locally; the existing website bundle is not a launch artifact of this
contracts-only assignment. Full results are recorded in the verification document.
