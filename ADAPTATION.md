# KEPT token and hook launch adaptation

Launch: `src/KeptToken.sol:KeptToken` and `src/KeptHook.sol:KeptHook` through the IMD Uniswap v4
hook factory on Robinhood Chain (4663), paired with IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`,
LP fee 12500, tick spacing 60, hook permissions `0x20cc` at a CREATE2-mined address. The earlier
contracts-only launch of `KeptVault` (now live at `0x3152f9cbf64d0c1ac24ea7e101db3e4d8da86896`) and
its adaptation notes are archived in
[docs/launches/vault-2172.adaptation.md](docs/launches/vault-2172.adaptation.md).

No transaction was signed or broadcast. No launch manifest is written by this step. Build
configuration, remappings, dependencies and lockfiles are unchanged, and nothing was installed.

## What already fit the launch

- **KeptToken** (`src/KeptToken.sol`, unchanged): name and symbol `KEPT`, 18 decimals, exactly
  `1_000_000_000 ether` (10^27 minor units) minted once to `msg.sender` in a constructor with no
  arguments. No owner, mint, burn, tax, pause, blocklist, hooks or upgrade path. The launch's rules
  for the token were already met, so only tests were added (`test/KeptToken.t.sol`).
- **KeptHook constructor** (`src/KeptHook.sol`, unchanged signature): nonpayable, five address-typed
  arguments in the launch's order `(IPoolManager $poolManager, IMD, $token, KeptVault, $factory)`,
  no external calls and no code-presence requirement, so it deploys on an empty chain. The only
  constructor check beyond non-zero arguments is `Hooks.validateHookPermissions` against the hook's
  own address bits, which the CREATE2 mining satisfies. The vault is an existing contract's address,
  which the manifest can name. `msg.sender` (the factory) and `tx.origin` are never stored as an
  owner; the hook has no owner at all. The factory address is stored only to gate initialization.
- **Pool initialization**: `beforeInitialize` is enabled, PoolManager-only, factory-only, single-use,
  pins the IMD/KEPT pair, fee 12500 and tick spacing 60, and returns its selector. Unchanged.
- **Swap callbacks**: `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`
  take the fee on the IMD leg only, for exact-input and exact-output buys and sells. Unchanged
  structure; only the rounding changed (below). The fee is kept in IMD as ERC-6909 claims and swept
  into the vault's Referee Fund, as the brief states, not converted to ETH.
- No liquidity callbacks exist, so the factory's zero-change fee collection is never blocked.
- No `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE`, proxy, initializer or post-deployment
  setter in either contract (scanned by `test/KeptHookLaunch.t.sol`). Every library the hook calls
  is `internal`, so the bytecode has nothing to link.

## Imported findings and reproductions

### d96e756ad7e93225588421a8383f7cf9de819057348bdd74c496a0c1fde5052b — fee rounds down (low)

Reproduced by reading the four fee expressions in `beforeSwap` and `afterSwap`: every one floored,
so an IMD leg below `10_000 / rate` wei paid nothing (4 wei at 20%, 99 wei exact-in and ~93 wei
exact-out at 1%).

Changed `src/KeptHook.sol`: a private `_feeOf(amount, numerator, denominator)` computes
`ceil(amount * numerator / denominator)` and replaces every floor, in `beforeSwap` (the reserve, the
partial-fill exact-input fee and the exact-output fee) and in `afterSwap` (both legs). The fee is
now `ceil(gross IMD * feeNow / 10_000)` in all four modes: for the two modes where the hook charges
on top of the pool's IMD amount `x`, `ceil(x * r / (10_000 - r))` equals `ceil((x + fee) * r / 10_000)`,
so the user-facing rate is the same ceiling everywhere. The existing bounds hold: the fee never
exceeds the IMD leg, a full exact-input fill still charges exactly the reserve, and a full
exact-output fill still delivers exactly the requested amount. `_accrue` still skips a zero fee, which
now only happens when the pool moves no IMD at all (for example a dust sell whose IMD output rounds
to zero inside the pool).

Tests: `test/helpers/HookFixture.sol` now asserts the ceiling formula on every checked swap in both
currency orders, that the fee never exceeds the IMD leg, and that any nonzero IMD leg pays at least
one wei. `test_dustSwapsRoundTheFeeUp` reproduces the audit's 4-wei, 99-wei and exact-output cases
and `testFuzz_dustSwapsAlwaysPay` fuzzes sub-10_000-wei swaps across the schedule. The fork
rehearsal also charges a 4-wei buy one wei on the live PoolManager.

### 79f4aafb3d6bbb5ce20684ef002544475764996f5fbd038a42536d96788993ff — window timed from initialize (low)

Reproduced: `beforeInitialize` wrote `openedAt`, so a pool whose liquidity arrived later than its
initialization could reach the steady 1% before anyone could trade. Whether the factory initializes
and seeds in one transaction cannot be confirmed from this repository, so the window was made
independent of that timing, as the finding suggested.

Changed `src/KeptHook.sol`: `openedAt` stays zero at initialization (`Initialized` is emitted
instead) and is set, with `Opened`, by the first swap that moves IMD, inside `_accrue`. `feeNow()`
returns the opening 20% until then and decays over the 30 minutes that follow that first trade.
A swap against an empty pool moves no IMD and does not start the clock, so the window cannot be
consumed before liquidity exists. The schedule, rates and duration are unchanged.

Tests: `test_feeSchedule`, `test_openingClockStartsAtFirstSwapNotInitialize` (seeded pool left
untouched for 30 minutes still charges 20% on its first trade, then decays from that moment),
`test_openingClockNeedsAnIMDLeg`, and the fork rehearsal, where liquidity is seeded after
initialization and the first trade half an hour later pays the opening fee. Existing timing tests
call the fixture's `_open()` so they measure the schedule from a first trade at the fixture's
opening time, as they did from initialization before.

### db1b11d05e5c9617e6891dee2278f0d7baa9ae7ff87ca5a5412d512f7990ec6d — coverage (info)

Not a defect; nothing to change. Its observations (constructor order, permissions, single-use
factory-only initialization, claim accounting, sweep guards, no admin surface) are now also
asserted by `test/KeptHookLaunch.t.sol` and `test_constructorArgumentsInLaunchOrder`.

## Changes outside the contracts

| File | Change | Why |
| --- | --- | --- |
| `test/KeptHook.t.sol`, `test/helpers/HookFixture.sol` | Ceiling expectations, `_open()`, regression tests for both findings, constructor-order and double-initialize checks | Every change is tested; existing timing tests adapted to the window's new start |
| `test/KeptToken.t.sol` | New | The launch token's supply, transfer, allowance and absence of admin entry points |
| `test/KeptHookLaunch.t.sol` | New | Rehearses the launch shape locally: empty chain, CREATE2 at a mined `0x20cc` address, exact argument order, no value, runtime size and opcode scan |
| `test/fork/Robinhood.t.sol` | Hook rehearsal uses the deployed vault and the launch argument order; verifies the vault's IMD; covers late seeding, dust rounding and a permissionless sweep | The brief requires a fork rehearsal on the live PoolManager for this launch |
| `web/src/abi/KeptHook.json` | Regenerated | New `Initialized` event |
| `README.md`, `docs/SPEC.md`, `docs/VERIFICATION.md` | This launch's arguments, fee semantics, callbacks, and the current rehearsal record | Required by the brief |

## Validation

`forge build --offline` and `forge test --offline` with
`FOUNDRY_FUZZ_SEED=0x1cacf04b210f5bc3adc0aa32053cf59f520528175c4bad608c637a003db5baa6`: 153 passed,
0 failed, 1 skipped (the fork suite, offline). The fork suite passed at Robinhood block 92,017,157;
see [docs/VERIFICATION.md](docs/VERIFICATION.md).
