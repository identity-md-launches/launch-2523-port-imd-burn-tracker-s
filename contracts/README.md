# BurnTracker payer

This directory is an independent Foundry project. The existing site, refresh code, package files, and root build configuration are unchanged. Only `BurnTrackerTest` is intended for the first launch. It inherits `BurnTracker` and forwards the constructor arguments without adding storage or behavior. Neither contract creates a token, pool, proxy, or helper contract.

## Build and verify

Run from this directory:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd06814b3f3424e7ad5413e509881e44f0ec28bb099287513d85c796daf0cb7c0 forge test
forge fmt --check
```

Solidity is pinned to **0.8.26**, with optimizer 200 runs, IR compilation, and the Cancun compiler target. Metadata and CBOR are disabled so the two deployment names have **identical runtime bytecode**, checked by a test. All dependencies and result fixtures are ordinary files in this directory. Default tests require no network, filesystem cheatcodes, environment variables, FFI, or credentials. The mainnet suite explicitly skips without a supplied fork.

The suite also passes with optimization/IR disabled and default IPFS metadata enabled, matching the supplied failing check's compiler behavior. In that mode, the runtime comparison normalizes only the recognized Solidity 0.8.26 metadata hash; all instructions and the metadata envelope must still match. The pinned project's complete artifacts are byte-for-byte equal without normalization. See [VERIFICATION.md](VERIFICATION.md) for both checks and gas measurements. No build configuration or dependency was changed for this repair.

The integration suite uses actual Ethereum Intake v2 and IMD bytecode and storage at block **26258169**:

```sh
FOUNDRY_FUZZ_SEED=0xd06814b3f3424e7ad5413e509881e44f0ec28bb099287513d85c796daf0cb7c0 \
  forge test --match-contract MainnetForkTest \
  --fork-url https://eth.drpc.org --fork-block-number 26258169 -vv
```

This runs locally on a fork. It does not broadcast or ask the off-chain swarm to execute work. Test balances are provisioned with Foundry and the protocol's writer is impersonated to test delivery. The Intake itself performs the real payment and records the deployed tracker as payer. See [VERIFICATION.md](VERIFICATION.md) for results and gas accounting.

## Launch parameters

Deploy **`BurnTrackerTest`**, with these nine arguments in order:

| Argument | Value |
| --- | --- |
| `owner_` | The later launch's payer, supplied explicitly by the launch as `$owner` |
| `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| `asset_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| `openAction_` | `bytes32("job.open@job-1")` |
| `continueAction_` | `bytes32("job.continue@job-1")` |
| `bodyPrefix_` | UTF-8 bytes before `{{PARENT}}` in `continuation-template.json` |
| `bodySuffix_` | UTF-8 bytes after `{{PARENT}}` in that same file |
| `cooldown_` | `86400` |
| `staleAfter_` | `172800` |

`script/LaunchParameters.sol` contains the exact addresses and byte-string template parts used in tests. Action IDs are right-padded UTF-8, **not hashes**:

```text
open:     0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000
continue: 0x6a6f622e636f6e74696e7565406a6f622d310000000000000000000000000000
```

The template file has no trailing newline. Split its bytes at its single literal `{{PARENT}}`; do not parse and reserialize it, escape its apostrophes differently, or insert whitespace. The prefix is `{"parentJobId":"`. The contract inserts exactly 36 lowercase UUID bytes and then the suffix. The exact instruction text is preserved in the file and is compared against the emitted Intake body in tests.

The constructor makes no external calls and does not require code at the Intake or asset. This permits the launch's empty-chain check. It rejects zero addresses/actions, empty template parts, a template that would exceed Intake's 16 KiB body limit, and timing values outside the inclusive **1 hour–30 days** range. The factory and `tx.origin` never determine ownership. This assignment supplies no launch manifest and performs no deployment.

## Operating the tracker

1. The owner obtains and previews a valid `job.open` body that imports this repository, builds it using its existing package script with network access, and hosts `dist/`. Approve the tracker to spend the live open-action price, then call `open(body)`. This initial order must be made **through the tracker**. An older project paid for by a different address cannot be transferred to this payer by naming its job ID.
2. Observe `Updated` and fetch the **unchanged response bytes** from its result URI. Hash those bytes with Keccak-256; JSON reformatting changes the proof. The contract records only the hash and emits the URI.
3. Once `status().state == 2` and `block.timestamp >= nextUpdateAt()`, any caller approves the tracker for the current IMD price and calls `updateBurntracker(resultBytes, maxPrice)`. The caller pays exactly the live continuation price. A zero price means not sold. A price above `maxPrice` reverts before any token call. The tracker approves the Intake for exactly the price and leaves no payment allowance or newly deposited balance behind.
4. Keep watching for completion, failure, or a missed callback. No autonomous timer or keeper is included. Anyone may fund an eligible update; someone must submit the transaction and pay its gas.

`price()` quotes the **continue** action, in the asset's smallest units. Quote the open action directly through Intake for initial setup. Open and recovery have no `maxPrice` parameter in the required interface; the owner can bound spending with the allowance they grant the tracker. Payments are forwarded by Intake immediately and **are not refundable**, including refused jobs. `Ordered.payer` is the funding caller; the Intake's recorded payer is always the tracker.

## State and recovery

States: `UNOPENED=1`, `IDLE=2`, `PENDING=3`, `STUCK=4`. Order kinds: `OPEN=1`, `CONTINUE=2`, `RECOVER=3`. Only one request is awaited at a time.

| Awaited order | Success | Refused, status 1 | Failed, status 2 |
| --- | --- | --- | --- |
| Open | IDLE; save hash; restart cooldown | UNOPENED | STUCK |
| Update | IDLE; save hash; restart cooldown | IDLE; keep last hash; restart cooldown | STUCK |
| Recover | IDLE; save hash; restart cooldown | STUCK | STUCK |

An owner may `recover(parentJobId)` or `setResultHash(hash)` in IDLE, STUCK, or once a pending order reaches its recorded `staleAt`. Neither is allowed before opening. Recovery validates the UUID and submits the same stored continuation template, paid by the owner, without waiting for cooldown. Hash adoption submits no order, abandons any stale awaited request, enters IDLE, and restarts cooldown. The owner must independently verify that the selected parent/completion belongs to this payer and is the newest usable job. The plane can still refuse an obsolete parent, a parent whose GitHub delivery is unfinished, or a project with running work.

`open()` may be retried from UNOPENED, STUCK, or stale PENDING. It is unavailable from IDLE. Reopening starts a fresh hosted project; it does not cancel an old off-chain job. Blocked jobs and missing callbacks therefore cannot permanently lock the payer, but retrying too early can spend another price on a refusal.

Decisions where the brief left details open:

- Staleness and cooldown use inclusive boundaries: `now >= deadline`. `staleAt` is fixed when ordering. Changing `staleAfter` affects future orders only; changing cooldown affects the current cooldown deadline immediately.
- Passing the stale time alone does not discard an order. Its callback is still accepted until the owner replaces/adopts it. A replaced request's callback is rejected, even if it comes from a formerly configured Intake.
- A pending order remembers the Intake that accepted it. `setIntake` affects future orders; the original Intake alone can settle the current request.
- `pendingKind` becomes zero after settlement/adoption. `orderedAt`, `staleAt`, and `lastRequestId` retain the most recent order's history. `nextUpdateAt()` always returns `lastDone + cooldown`; eligibility additionally requires IDLE. Before the first completion, `lastDone` is zero.
- Hash zero is rejected. The initial nonzero `resultHash` is an allocation sentinel, not a usable proof. The initial UNOPENED state prevents using it.
- UUID validation checks lowercase hexadecimal in the `8-4-4-4-12` format, without restricting UUID version or variant bits.
- Tokens must transfer the exact amount without fees or rebasing during the order. Optional ERC-20 return values and zero-first approvals are supported; fee tokens are rejected. `withdraw` handles ERC-20 tokens, not native currency.

## Proof reader and callback budget

`parentJobIdOf(bytes)` validates JSON grammar, counts `jobId` object keys across all nesting, and validates the UUID. It handles escaped quotes/backslashes in values, JSON whitespace, numbers, arrays, and nested objects. It accepts at most 16 KiB and 64 nesting levels. As required by canonical Intake documents, object keys must be unescaped; escaped aliases such as `job\u0049d` are rejected. It does not validate UTF-8 normalization or key sorting.

The update path **first** requires `keccak256(resultJson) == resultHash`. It then uses a word-at-a-time reader for those authenticated, canonical bytes, counting the same literal, unescaped key and checking its UUID. This reader relies on the supplied protocol fact that completion documents are canonical JSON; it does not revalidate unrelated number/container grammar. An unescaped `"jobId"` followed by a colon is a key in valid JSON; escaped quotes inside a value cannot forge it. The owner must only adopt actual canonical completion hashes. Fuzz and fixture tests compare both readers on valid inputs, and test forged/duplicate keys through the update path.

The reader filters 128-byte chunks for candidate keys, then checks the complete key and escape context. Bounds exclude unrelated trailing calldata. UUID classification validates ASCII byte ranges in parallel; tests exhaust every possible byte at each of the 36 positions, including separators and high-bit bytes. Payment calls use fixed-size ABI buffers with optional ERC-20 return checks and revert propagation; SafeERC20 provides the zero-first approval fallback and withdrawals. The reentrancy guard shares the status slot to avoid a second storage write charge on each order.

Both callbacks check sender, awaited request ID, PENDING, and that no order/payment is in progress. They perform no token transfer, JSON parsing, or external call. Only `resultHash` and one packed status word are written by a result; failure only writes the status word. **Both slots are nonzero from construction and remain nonzero.** This avoids the supplied post-Glamsterdam approximately 111,000-gas zero-to-nonzero storage charge. The URI and failure reason are logged rather than stored. Tests cap calls at 200,000 gas and inspect every storage write against constructor values and previous/new values, for first/repeated success and all six failure transitions.

## Owner powers and responsibilities after launch

The owner can change the complete future objective (`setBody`), action versions (`setActions`), Intake/token (`setIntake`), and timing (`setTiming`), adopt hashes, recover/reopen projects, and withdraw tokens sent to the contract. These are deliberate trust assumptions. Updates are fixed relative to the **current owner-controlled template**, not immutable for the contract's lifetime. Ownership transfers require the nominated address to call `acceptOwnership`; there is no renunciation function.

Before opening and after any configuration change, preview the complete body with the public request checker, verify the live price and protocol addresses, and ensure GitHub/IPFS delivery is enabled as intended. Keep an owner able to respond to missed/blocked jobs. Monitor delivery as well as on-chain completion, retrieve original result bytes, and check the project is eligible before spending on recovery. Verify the deployed source and constructor settings after the separate launch. No operator wallet, private key, or scheduled service is included here.

The exact continuation template was previewed against completed sample parent `61d5c470-fe09-408e-bca5-a047d037e610`: **no blockers**. A preview against this repository's preceding job reported that this assignment was still running, as expected. The saved responses are under `test/fixtures/template-preflight*.json`. A successful sample preview does not override the plane's payer, newest-parent, and delivery checks at actual admission.

## Dependencies and evidence

- `vendor/openzeppelin`: the unmodified SafeERC20 subset from OpenZeppelin Contracts **v5.0.2**, with its license. Only internal library functions are used, so no link placeholders or library deployments are required.
- `vendor/forge-std`: unmodified source and licenses from **v1.9.7**, used only by tests.
- `test/fixtures/provenance.json`: seven real completed Intake result documents, 750–4,545 bytes, with source URLs, request IDs, Keccak hashes, completion transactions, and blocks. Documents are stored unchanged and embedded in Solidity so offline tests read their exact bytes.
- `script/embed-fixtures.py`: verifies recorded sizes/hashes/canonical encoding and regenerates the embedded test fixtures. It uses Python's standard library and the already-required `cast` binary, with no network.

Behavior and administration tests cover access control, token failures, exact payment/body bytes, reentrancy, configuration changes, ownership, and every state transition. Parser tests include fuzzing and every truncation of a real 750-byte document. The offline gas regression and optional live fork test use the actual 4,545-byte document. The structural callback test explicitly guards against new storage allocation. These checks are implementation evidence, not an independent security audit.
