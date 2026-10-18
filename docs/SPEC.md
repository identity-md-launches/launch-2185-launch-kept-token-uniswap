# KEPT — promises the swarm enforces

> The team only gets paid when it ships, and the IMD swarm is the referee.

KEPT lets any project lock tokens behind public milestones. At each deadline the IMD
reasoning oracle checks the milestone and signs a verdict for the KEPT contract. A kept
milestone releases its tokens to the team. A broken one burns them.

Chain: Robinhood Chain (4663). Everything is paid in IMD.

## Parts

| Launch | Kind | Contracts | Purpose |
| --- | --- | --- | --- |
| 1 | `evm_contracts` | `KeptVault` | The product. Open to every project, no token. |
| 2 | `univ4_hook` | `KeptToken`, `KeptHook` | KEPT/IMD pool. The hook's IMD fee funds the Referee Fund in `KeptVault`. The KEPT team locks its own share in a pledge. |

Launch 1 goes first; its address is a constructor argument of `KeptHook`.

## Concepts

- **Pledge**: one project's promise set. It names the locked `token`, the `beneficiary`
  that receives kept tranches, a `name`, the panel settings snapshotted at creation, and an
  IMD `budget` that pays for checks.
- **Milestone** (1–8 per pledge): a template, its parameters, a `deadline`, a token
  `amount`, and a display `title`. Its outcome is `Open`, `Kept` or `Broken`.
- **Check**: one oracle question bought from the IMD Intake for one milestone
  (0.5 IMD today, read live from `Intake.priceOf`).
- **Referee Fund**: IMD anyone can donate (the KEPT hook does so continuously). When a
  milestone is verified kept, the fund rebates the price of one check to that pledge's budget.
  Keeping a promise costs nothing; breaking one means the team paid for its own verdict.
  The rebate is unconditional on what was pledged: any pledge on any ERC-20 whose milestone the
  oracle answers kept, including one that is already true when it is created, draws it. The fund
  is therefore a public subsidy for oracle checks of kept milestones, not a reward reserved for
  the KEPT team or for pledges of any particular value.

## Milestone templates

Free-form promises are not accepted: vague questions are what make oracle panels disagree.
Each template produces one precise yes/no question. User strings are restricted to a safe
character set and length, so they cannot break the JSON body or the question's sentence.

| Template | Parameters | Evidence | Question (abridged) |
| --- | --- | --- | --- |
| `GithubRelease` | `repo` (`owner/name`), `tag` | panel | Does github.com/`repo` have a published, non-draft release tagged exactly `tag`, published at or before the deadline? |
| `PageContains` | `url` (https), `text` | panel | Does `url`, fetched now, respond successfully and contain the exact text `text`? |
| `ContractDeployed` | `chainId`, `target` | chain | On chain `chainId`, does `target` have contract bytecode at the closing block? |
| `ValueAtLeast` | `chainId`, `target`, `function`, `threshold` | chain | On chain `chainId`, does calling `function` on `target` return a uint256 ≥ `threshold`? |

Supported question chains: Ethereum 1, BNB 56, Robinhood 4663, Base 8453, Arbitrum 42161
(the list `POST /requests/check` reports). On 9 Oct 2026 the exact bodies `KeptVault` generates
for all four templates passed `POST /requests/check` with no blockers, and were accepted by
`POST /requests/quote` (unpaid), which applies the same validation as the Intake.

## Lifecycle

1. `createPledge(token, beneficiary, name, milestones, budget)` pulls the summed token
   amounts and the IMD budget. Fee-on-transfer tokens are refused (exact balance delta).
   Each deadline must be at least one hour and at most three years ahead.
2. `check(pledgeId, index)` buys a question:
   - only the beneficiary may call it, from creation to prove early delivery. A separate
     creator cannot spend the beneficiary's attempts;
   - `PageContains`, `ContractDeployed` and `ValueAtLeast` checks close at the deadline
     (inclusive). Their attestations must also be signed by the deadline; ask sufficiently
     early for asynchronous processing. A timely, unexpired signature can arrive later;
   - `GithubRelease` checks remain open through `deadline + GRACE` (3 days), because the
     question explicitly checks publication by the deadline;
   - at most `MAX_ATTEMPTS` (3) per milestone, one in flight at a time;
   - the price comes out of the pledge budget; anyone can top it up with `fund`. The
     two-argument call caps the quote at `DEFAULT_MAX_PRICE = 0.5 IMD`. The overload
     `check(pledgeId, index, maxPrice)` uses the beneficiary's explicit ceiling in IMD atomic
     units. A quote above the cap reverts without consuming budget or attempts. Both
     `checkOpen` overloads report `funded` only when the quote fits the budget and cap.
3. The Intake calls `onOracleResult(requestId, attestation, signature)`. KEPT accepts it
   only from the Intake that took the request, only for a request it made, only when signed
   by the oracle signer in KEPT's EIP-712 domain, for the right question chain, with at least
   the snapshotted panel size and quorum, `agreed >= quorum` for panel evidence (chain evidence
   may be settled by the deployer's rerun with fewer), issued after the ask, and as a
   bool. For the three snapshot templates, `issuedAt <= deadline` is also required.
   The signature is checked against the oracle signer recorded when the check was asked,
   so a signer rotation cannot strand a check already in flight. `true` marks the milestone `Kept` and pays the rebate if the fund can. `false` is
   recorded and the milestone stays `Open`. The callback only verifies and stores (it must fit
   200k gas); tokens move in `settle`.
4. A check with no answer after 24 hours can be cleared by anyone (`clearStale`), freeing the
   slot. The attempt still counts.
5. `settle(pledgeId, index)` is permissionless:
   - `Kept` → the tranche goes to the beneficiary;
   - still `Open` after `deadline + GRACE` with nothing in flight → `Broken`, and the tranche
     is sent to `0x…dEaD`.
   Unproven means broken: the burden of proof is on the team.
6. Once every milestone is settled, `withdrawBudget` (callable by anyone) returns the unused IMD
   budget to the creator. It is separate from `settle` so a refund can never block a payout.

## Trust model

- No one can move locked tokens except through a verdict or a missed deadline. The owner has
  no withdrawal, pause or upgrade path.
- The owner (the KEPT team wallet) can change the Intake, action id and oracle signer, which
  the IMD docs say must stay settable. Every change waits 7 days in public (`proposeProtocol`
  → `executeProtocol`), and requests already in flight stay bound to the Intake that took them.
  Panel size and quorum changes apply to new pledges only. Ownership can be renounced. The
  website shows a warning on every page while a change is pending.
  Locked pledges have no exit during the notice. A replacement signer can approve future
  checks on existing pledges, so the delay gives notice, not protection from a dishonest owner.
- IMD (the payment asset) is immutable.
- Known limits: a creator controls the strings in their own question, so the panel is the last
  line of defence against wording games (the character set blocks quoting tricks; quorum 7 of 9
  by default). A milestone the swarm cannot confirm is broken, so teams should pick templates
  they can prove. Value thresholds must be above zero. The page-text template tells the panel the quoted text is a literal string, never an
  instruction.
- Verdicts arrive only through the Intake callback, bound to the Intake request that asked.
  There is deliberately no public `submit` for re-delivery: KEPT cannot recompute the oracle's
  question hash (the oracle pins the block window and may add definitions after the request), so
  a public path would let a valid verdict for one milestone be replayed onto
  another. A callback that never lands times out after 24 hours and the milestone can be asked
  again. KEPT therefore trusts IMD's Intake to hand each request its own verdict, as every other
  oracle consumer does; each verdict can be used once. The heaviest callback path (kept + rebate) is tested to stay under 150k of the 200k gas.
- Page and chain milestones remain point-in-time snapshots selected by the beneficiary before
  the deadline. A temporary condition can satisfy them; they do not promise continuous validity
  or a measurement at the exact deadline. This preserves early proof without allowing late
  delivery to qualify. Missing, refused or late-signed evidence can still cause a burn.
- Only plain ERC-20s with exact transfers and stable custody balances are supported. Do not
  deposit rebasing, balance-decaying, confiscatable or transfer-restricted tokens, or tokens
  that can be upgraded to those behaviours. Fee-on-transfer deposits are refused by their
  balance delta; future incompatibility cannot be inferred from an ERC-20 interface.
  Custody is shared per token, with nominal amounts: after a balance shrink, earlier settlements
  can leave the last tranche unpayable and its IMD budget permanently blocked by `open != 0`.
  There is no pro-rata accounting or rescue. See the explicit compatibility tests.

## KEPT token and hook

- `KeptToken`: KEPT / KEPT, 18 decimals, fixed 1,000,000,000 minted to the launch factory.
  No owner, mint, tax or pause.
- `KeptHook`: immutable fee hook for the single KEPT/IMD pool (LP fee 12500, tick spacing 60).
  It charges a fee on the gross IMD leg of every swap, rounded up: 20% at opening, decaying
  linearly to 1% over 30 minutes (anti-snipe), then 1% forever. The window starts at the first
  swap that moves IMD through the pool, not at pool initialization, so it cannot elapse before
  the pool holds liquidity; a swap the pool fills nothing of (an empty pool, or 1 wei that is
  all fee) is charged but does not start it.
  Fees accrue as PoolManager ERC-6909 claims; anyone can call `sweep()`, which redeems
  them and deposits the IMD into the KEPT Referee Fund. Fee math is adapted from the accepted
  imdDRONE hook (launch 909). Only the launch factory (`$factory`) may initialize the pool, as on
  the live imd.place hook. Permissions `0x20cc`. Constructor: `$poolManager`, IMD, `$token`, the
  deployed `KeptVault`, `$factory`.
- The team's launch allocation goes into a public KEPT pledge right after launch, with
  milestones dated inside the hackathon window so judges can see real verdicts and settlements.

## Launch plan

1. Publish this repository publicly; `POST /requests/import` with `kind: contracts`.
2. Launch 1: `launch.open`, `onchain: "evm_contracts"`, `chainId: 4663`, `owner: <team wallet>`,
   deploy only `KeptVault`.
3. Launch 2: `launch.open`, `onchain: "univ4_hook"`, `chainId: 4663`, `pairWith: "imd"`,
   `economics: {poolBps, remainderTo: <team wallet>}`, deploy `KeptToken` + `KeptHook` with the
   vault address.
4. Lock the team share in a pledge, run the first checks, build the site, file on IMD Radar.
