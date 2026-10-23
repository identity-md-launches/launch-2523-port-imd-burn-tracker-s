# Verification evidence

Checks were performed on 2026-10-24 with Solidity **0.8.26** and Foundry **1.8.3**, using the compiler settings in this directory's `foundry.toml`. The task's supplied fuzz seed was used:

```text
0xd06814b3f3424e7ad5413e509881e44f0ec28bb099287513d85c796daf0cb7c0
```

## Local checks

- `forge build`: passes.
- `forge test`: **66 passed, 0 failed**, covering offline behavior, ownership/configuration, proof/parser, callback-storage, and update gas. The fork suite skips explicitly without a fork and is run separately below.
- `forge fmt --check`: passes.
- The six fuzz properties run 256 cases each using the supplied seed.
- `BurnTracker` and `BurnTrackerTest` have byte-for-byte equal deployed runtime code, including the complete compiled output (metadata disabled): **12,347 bytes each**. The artifact byte strings were also compared directly, without any normalization.
- The constructor succeeds with no code at the supplied mainnet Intake/token addresses.
- The exact template and an instantiated continuation body are pinned by independently calculated Keccak hashes in the tests.
- Every byte truncation of the real 750-byte API document is rejected by the strict parser.
- Repair changes are confined to `contracts/`. The existing Foundry configuration, vendored dependencies, site, refresh scripts, and package files are unchanged.

## Repair of the supplied check failures

Both failures were reproduced with optimization/IR disabled and IPFS metadata enabled: the 4,545-byte update took **327,797 gas**, and the two contract names had different metadata hashes. The existing `contracts/foundry.toml` already disabled metadata and enabled optimization, under which the original two checks passed. It was left unchanged.

The update implementation now filters larger input chunks, validates UUID bytes in parallel, packs the reentrancy guard into the status word, and uses fixed-size ERC-20 call buffers. Proof authentication, duplicate-key detection, exact payment, and approval bounds remain checked. Added regressions cover every byte value at every UUID position, scan boundaries and false-positive candidates, unrelated trailing calldata, malformed token return values, revert propagation, and rollback of the guard and payment.

The runtime test compares the complete code under the pinned settings. For externally compiled builds that include the default Solidity 0.8.26 CBOR trailer, it recognizes the entire 53-byte trailer and normalizes **only its 32-byte IPFS metadata hash**, preserving checks on every executable byte, the trailer format, compiler version, and encoded trailer length. Different compilation targets necessarily have different metadata hashes; see the [Solidity metadata specification](https://docs.soliditylang.org/en/v0.8.26/metadata.html). `BurnTrackerTest` itself is unchanged and still adds only constructor forwarding.

The complete suite was also run with these overrides from `contracts/`, using separate scratch artifacts and the same supplied fuzz seed:

```sh
FOUNDRY_OPTIMIZER=false FOUNDRY_VIA_IR=false \
FOUNDRY_CBOR_METADATA=true FOUNDRY_BYTECODE_HASH=ipfs \
FOUNDRY_FUZZ_SEED=0xd06814b3f3424e7ad5413e509881e44f0ec28bb099287513d85c796daf0cb7c0 \
forge test --out ../test/scratch/unoptimized-out --cache-path ../test/scratch/unoptimized-cache
```

Result: **66 passed, 0 failed**, with the fork suite explicitly skipped. Its offline update measurement is **299,240 gas**, including the existing measurement wrapper's CALL/encoding overhead. The test's 300,000-gas ceiling was not changed.

## Mainnet integration and gas

The two `MainnetForkTest` tests pass against Ethereum block **26258169**, fetched through `https://eth.drpc.org`. The previously documented PublicNode endpoint now requires a personal token for archive calls; no token or credential is needed by the replacement used for these checks. They use the real contracts:

| Contract | Address |
| --- | --- |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |

At this block both job actions cost `500000000000000000` raw IMD; the token reports symbol `IMD`; the Intake callback limit is `200000`. The real `requests(requestId)` getter records the newly deployed tracker as payer and callback target, with the expected result selector and failure hook. Tests confirm exact payment, zero remaining Intake allowance, emitted continuation bytes, successful result delivery, and refused-update delivery through the actual Intake.

For the original **4,545-byte** result document `test/fixtures/08f07d6f.json`:

| Measurement | Gas |
| --- | ---: |
| Update through real Intake/IMD on the fork, pinned compiler settings | **287,984** |
| Offline update through the protocol mock, pinned compiler settings | **291,746** |
| Offline update through the protocol mock, unoptimized legacy compiler settings | **299,240** |

These are **execution gas**, before refunds, measured around the nested `updateBurntracker` call with all involved accounts and storage made cold. They include the caller's CALL/encoding overhead. The test-only `UpdateCaller` prevents Foundry isolation from mixing a separate transaction's intrinsic/calldata gas into this measurement. The 300,000 assertion applies to the function call; a transaction's total gas also includes intrinsic/calldata charges. Do not use 300,000 as a transaction gas limit: estimate the actual transaction. The mock's figure is slightly higher because it contains additional test instrumentation. No mock replaces either mainnet contract in the fork test.

Callback tests use an actual **200,000-gas capped CALL**, including first/repeated result delivery and all combinations of three order kinds and two failure statuses. All succeed. A 4 KiB URI is also tested. More importantly for the supplied post-Glamsterdam storage pricing, every callback storage write is recorded and checked to have:

1. A nonzero value immediately after deployment.
2. A nonzero value immediately before the callback write.
3. A nonzero value immediately after the callback write.

The result callback touches only the preinitialized result-hash slot and packed status slot. Failure only touches the packed status slot. This storage evidence is independent of the Cancun gas schedule used by the pinned compiler/test configuration and prevents first-callback zero-to-nonzero allocations under the supplied later storage pricing.

The largest measured callback, including the 4 KiB URI and call overhead, used **87,039 gas** under the pinned settings and **90,143 gas** without optimization. No callback storage allocation was observed in either build.

## Real result provenance

`test/fixtures/provenance.json` records source URLs, exact lengths, Keccak hashes, on-chain request IDs, request actions/transactions, and completion transactions/blocks. Six fixtures are job.open/job.continue results; one additional fixture is a launch.open result with the same job-result envelope. Each was downloaded from its emitted result URI (the API or an IPFS gateway) and checked against the real Intake's `Completed` event hash before embedding.

The largest fixture's evidence:

- Request: `0x08f07d6ff48974669d2d2fd3de5d26df9ecad4c1eaee7c71b69e8ebafeed13ad`
- Job: `61d5c470-fe09-408e-bca5-a047d037e610`
- Keccak-256: `0x03558189cf2730a5d0c515eb3d7b71aa4c1e4887645912b0c14fb1c550d8f692`
- [Completion transaction](https://eth.blockscout.com/tx/0xf6326427f777668cf4ff61c6a20eaa082102ecd1ad05cbb64541f68871572f77), block `26251666`.
- [Original IPFS result bytes](https://gateway.pinata.cloud/ipfs/bafybeifk66t64e5vkx6yjg5jsdjzy4jdszorp3mieejm2obcsw4jlukpd4/result.json).

The fixtures are not generated examples or padded documents. Their exact bytes are embedded in `RealResults.sol`, so deleting scratch files or disabling network access does not remove the evidence used by tests. `script/embed-fixtures.py` independently checks each document's size, recorded hash, job ID, completed state, and canonical serialization before regenerating the embedding.

During this repair, all seven recorded completion hashes and transactions were rechecked through the Intake API. The 750-byte API document was downloaded again and matched the committed bytes. The largest fixture's hash was additionally checked against its actual mainnet completion receipt through the RPC; its committed bytes remain unchanged. The fixture verification/regeneration script passed for all seven documents.

The public `/requests/check` preview returned no blockers for the exact continuation template with the completed largest-fixture parent. A separate preview against the actual preceding project job reported this assignment's running job and refused continuation while it runs. Both responses are saved. This was validation only; no payment, launch, or transaction was sent.

Slither/Mythril and an independent audit were not run. The implementation was reviewed locally for the supplied failure patterns: restricted caller-funded transfers, bounded exact approvals, callback authentication/replay resistance, storage allocation, reentrancy, UUID/JSON injection, recovery authority, and unchanged site/build files.
