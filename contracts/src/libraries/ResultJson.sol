// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Bounded JSON reader for canonical Intake result documents.
/// @dev Validates JSON grammar, counts jobId keys throughout the document, and treats string
/// escapes as data. Object keys must be unescaped (as in canonical Intake documents). String
/// values may contain JSON escapes and UTF-8. UTF-8 normalization and key ordering are not checked.
library ResultJson {
    error InvalidResultJson();

    function parentId(bytes calldata json) internal pure returns (bytes memory id) {
        if (json.length == 0 || json.length > 16_384) revert InvalidResultJson();
        uint256 position;
        assembly ("memory-safe") {
            function bad() {
                mstore(0, 0x777873aa) // InvalidResultJson()
                revert(28, 4)
            }
            function charAt(p) -> c { c := byte(0, calldataload(p)) }
            function white(c) -> yes {
                yes := or(or(eq(c, 32), eq(c, 9)), or(eq(c, 10), eq(c, 13)))
            }
            function ws(p, end) -> q {
                q := p
                for {} and(lt(q, end), white(charAt(q))) {} { q := add(q, 1) }
            }
            function hexDigit(c) -> yes {
                yes := or(and(gt(c, 47), lt(c, 58)), or(and(gt(c, 64), lt(c, 71)), and(gt(c, 96), lt(c, 103))))
            }
            // Exact zero-byte mask: no borrow-induced false positives on adjacent bytes.
            function zeroMask(x) -> mask {
                let low := 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f
                mask := not(or(or(add(and(x, low), low), x), low))
            }
            // Index of the first marked byte, most significant first. No per-byte loop.
            function firstByte(mask) -> n {
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffff)) {
                    n := 16
                    mask := mul(mask, 0x100000000000000000000000000000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 8)
                    mask := mul(mask, 0x10000000000000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 4)
                    mask := mul(mask, 0x100000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 2)
                    mask := mul(mask, 0x10000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 1)
                }
            }
            // Return one past the closing quote, and whether an escape occurred.
            function str(p, end) -> q, escaped {
                if iszero(eq(charAt(p), 34)) { bad() }
                q := add(p, 1)
                for {} lt(q, end) {} {
                    let word := calldataload(q)
                    let mask :=
                        or(
                            or(
                                zeroMask(xor(word, 0x2222222222222222222222222222222222222222222222222222222222222222)),
                                zeroMask(xor(word, 0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c))
                            ),
                            zeroMask(and(word, 0xe0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0))
                        )
                    if iszero(mask) {
                        q := add(q, 32)
                        continue
                    }
                    let n := firstByte(mask)
                    q := add(q, n)
                    if iszero(lt(q, end)) { bad() }
                    let c := byte(n, word)
                    q := add(q, 1)
                    if lt(c, 32) { bad() }
                    if eq(c, 34) { leave }
                    escaped := 1
                    if iszero(lt(q, end)) { bad() }
                    c := charAt(q)
                    q := add(q, 1)
                    switch c
                    case 117 {
                        if gt(add(q, 4), end) { bad() }
                        for { let j := 0 } lt(j, 4) { j := add(j, 1) } {
                            if iszero(hexDigit(charAt(add(q, j)))) { bad() }
                        }
                        q := add(q, 4)
                    }
                    default {
                        if iszero(
                            or(
                                or(or(eq(c, 34), eq(c, 92)), or(eq(c, 47), eq(c, 98))),
                                or(or(eq(c, 102), eq(c, 110)), or(eq(c, 114), eq(c, 116)))
                            )
                        ) { bad() }
                    }
                }
                bad()
            }
            function digit(c) -> yes { yes := and(gt(c, 47), lt(c, 58)) }
            function jsonNumber(p, end) -> q {
                q := p
                if eq(charAt(q), 45) { q := add(q, 1) }
                if iszero(lt(q, end)) { bad() }
                switch charAt(q)
                case 48 { q := add(q, 1) }
                default {
                    if iszero(digit(charAt(q))) { bad() }
                    for {} and(lt(q, end), digit(charAt(q))) {} { q := add(q, 1) }
                }
                if eq(charAt(q), 46) {
                    q := add(q, 1)
                    if iszero(and(lt(q, end), digit(charAt(q)))) { bad() }
                    for {} and(lt(q, end), digit(charAt(q))) {} { q := add(q, 1) }
                }
                if or(eq(charAt(q), 101), eq(charAt(q), 69)) {
                    q := add(q, 1)
                    if or(eq(charAt(q), 43), eq(charAt(q), 45)) { q := add(q, 1) }
                    if iszero(and(lt(q, end), digit(charAt(q)))) { bad() }
                    for {} and(lt(q, end), digit(charAt(q))) {} { q := add(q, 1) }
                }
            }
            function value(p, end, depth, found) -> q, result {
                if gt(depth, 64) { bad() }
                p := ws(p, end)
                if iszero(lt(p, end)) { bad() }
                result := found
                switch charAt(p)
                case 123 {
                    // Object: strings are keys only here, never when scanned as values.
                    q := ws(add(p, 1), end)
                    if eq(charAt(q), 125) {
                        q := add(q, 1)
                        leave
                    }
                    for {} 1 {} {
                        let start := q
                        let escaped
                        q, escaped := str(q, end)
                        if escaped { bad()} // Canonical keys have no escapes, including Unicode aliases.
                        let isJob :=
                            and(
                                eq(sub(q, start), 7),
                                eq(
                                    and(
                                        calldataload(start),
                                        0xffffffffffffff00000000000000000000000000000000000000000000000000
                                    ),
                                    0x226a6f6249642200000000000000000000000000000000000000000000000000
                                )
                            )
                        q := ws(q, end)
                        if iszero(eq(charAt(q), 58)) { bad() }
                        q := ws(add(q, 1), end)
                        switch isJob
                        case 1 {
                            if result { bad() }
                            start := q
                            q, escaped := str(q, end)
                            if or(escaped, iszero(eq(sub(q, start), 38))) { bad() }
                            result := add(start, 1)
                        }
                        default { q, result := value(q, end, add(depth, 1), result) }
                        q := ws(q, end)
                        switch charAt(q)
                        case 125 {
                            q := add(q, 1)
                            leave
                        }
                        case 44 { q := ws(add(q, 1), end) }
                        default { bad() }
                    }
                }
                case 91 {
                    q := ws(add(p, 1), end)
                    if eq(charAt(q), 93) {
                        q := add(q, 1)
                        leave
                    }
                    for {} 1 {} {
                        q, result := value(q, end, add(depth, 1), result)
                        q := ws(q, end)
                        switch charAt(q)
                        case 93 {
                            q := add(q, 1)
                            leave
                        }
                        case 44 { q := ws(add(q, 1), end) }
                        default { bad() }
                    }
                }
                case 34 {
                    let escaped
                    q, escaped := str(p, end)
                }
                case 116 {
                    if iszero(
                        eq(
                            and(calldataload(p), 0xffffffff00000000000000000000000000000000000000000000000000000000),
                            0x7472756500000000000000000000000000000000000000000000000000000000
                        )
                    ) { bad() }
                    q := add(p, 4)
                }
                case 102 {
                    if iszero(
                        eq(
                            and(calldataload(p), 0xffffffffff000000000000000000000000000000000000000000000000000000),
                            0x66616c7365000000000000000000000000000000000000000000000000000000
                        )
                    ) { bad() }
                    q := add(p, 5)
                }
                case 110 {
                    if iszero(
                        eq(
                            and(calldataload(p), 0xffffffff00000000000000000000000000000000000000000000000000000000),
                            0x6e756c6c00000000000000000000000000000000000000000000000000000000
                        )
                    ) { bad() }
                    q := add(p, 4)
                }
                default { q := jsonNumber(p, end) }
            }
            let end := add(json.offset, json.length)
            let start := ws(json.offset, end)
            if iszero(eq(charAt(start), 123)) { bad() }
            let finish
            finish, position := value(start, end, 0, 0)
            if or(iszero(position), iszero(eq(ws(finish, end), end))) { bad() }
        }
        id = new bytes(36);
        assembly ("memory-safe") { calldatacopy(add(id, 32), position, 36) }
        if (!isUuid(id)) revert InvalidResultJson();
    }

    /// @dev The caller MUST first authenticate canonical JSON against the Intake completion hash.
    /// The standalone parentId additionally validates the entire JSON grammar. Here we search
    /// words for candidate keys, reject escaped opening quotes, count every matching key, and
    /// validate its UUID. Within valid JSON an unescaped "jobId" followed by ':' is a key, never
    /// string content. Canonical JSON does not encode ASCII object keys using Unicode escapes.
    function authenticatedParentId(bytes calldata json) internal pure returns (bytes memory id) {
        if (json.length == 0 || json.length > 16_384) revert InvalidResultJson();
        uint256 position;
        assembly ("memory-safe") {
            function bad() {
                mstore(0, 0x777873aa) // InvalidResultJson()
                revert(28, 4)
            }
            function charAt(p) -> c { c := byte(0, calldataload(p)) }
            function white(c) -> yes {
                yes := or(or(eq(c, 32), eq(c, 9)), or(eq(c, 10), eq(c, 13)))
            }
            function ws(p, end) -> q {
                q := p
                for {} and(lt(q, end), white(charAt(q))) {} { q := add(q, 1) }
            }
            // Index of the first marked byte, most significant first. No per-byte loop.
            function firstByte(mask) -> n {
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffff)) {
                    n := 16
                    mask := mul(mask, 0x100000000000000000000000000000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 8)
                    mask := mul(mask, 0x10000000000000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 4)
                    mask := mul(mask, 0x100000000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 2)
                    mask := mul(mask, 0x10000)
                }
                if iszero(gt(mask, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) {
                    n := add(n, 1)
                }
            }
            let end := add(json.offset, json.length)
            if iszero(eq(charAt(ws(json.offset, end)), 123)) { bad() }
            let p := add(json.offset, 4)
            for {} lt(p, end) {} {
                // Most of a result is long paths, hashes and descriptions. Filter four
                // words together before resolving a candidate's exact byte position.
                let needle := 0x4949494949494949494949494949494949494949494949494949494949494949
                let ones := 0x0101010101010101010101010101010101010101010101010101010101010101
                let high := 0x8080808080808080808080808080808080808080808080808080808080808080
                let x := xor(calldataload(p), needle)
                let candidates := and(sub(x, ones), not(x))
                x := xor(calldataload(add(p, 32)), needle)
                candidates := or(candidates, and(sub(x, ones), not(x)))
                x := xor(calldataload(add(p, 64)), needle)
                candidates := or(candidates, and(sub(x, ones), not(x)))
                x := xor(calldataload(add(p, 96)), needle)
                candidates := or(candidates, and(sub(x, ones), not(x)))
                if iszero(and(candidates, high)) {
                    p := add(p, 128)
                    continue
                }
                // Scan for the less common capital I in "jobId", 32 bytes at a time.
                // The zero-byte filter can mark adjacent H bytes through borrowing;
                // the full-key comparison below rejects these harmless candidates.
                let word := xor(calldataload(p), 0x4949494949494949494949494949494949494949494949494949494949494949)
                let mask :=
                    and(
                        and(sub(word, 0x0101010101010101010101010101010101010101010101010101010101010101), not(word)),
                        0x8080808080808080808080808080808080808080808080808080808080808080
                    )
                if iszero(mask) {
                    p := add(p, 32)
                    continue
                }
                p := add(p, firstByte(mask))
                // A word load may see ABI padding or unrelated trailing calldata.
                if iszero(lt(p, end)) { break }
                let start := sub(p, 4)
                p := add(p, 1)
                if eq(
                    and(calldataload(start), 0xffffffffffffff00000000000000000000000000000000000000000000000000),
                    0x226a6f6249642200000000000000000000000000000000000000000000000000
                ) {
                    // Odd runs of backslashes escape the opening quote.
                    let back := start
                    for {} and(gt(back, json.offset), eq(charAt(sub(back, 1)), 92)) {} { back := sub(back, 1) }
                    if iszero(and(sub(start, back), 1)) {
                        let colon := ws(add(start, 7), end)
                        if eq(charAt(colon), 58) {
                            if position { bad() }
                            let quote := ws(add(colon, 1), end)
                            if or(
                                gt(add(quote, 38), end),
                                or(iszero(eq(charAt(quote), 34)), iszero(eq(charAt(add(quote, 37)), 34)))
                            ) { bad() }
                            position := add(quote, 1)
                        }
                    }
                }
            }
            if iszero(position) { bad() }
        }
        id = new bytes(36);
        assembly ("memory-safe") { calldatacopy(add(id, 32), position, 36) }
        if (!isUuid(id)) revert InvalidResultJson();
    }

    /// @dev UUID lexical form, 8-4-4-4-12 lowercase hexadecimal; no version restriction.
    function isUuid(bytes memory id) internal pure returns (bool valid) {
        if (id.length != 36) return false;
        assembly ("memory-safe") {
            // Classify all 32 ASCII bytes in parallel. Reject high bits first, so
            // the additions cannot carry between byte lanes. Each high bit then
            // marks exactly one byte in [0x30,0x39] or [0x61,0x66].
            function hexWord(x) -> yes {
                let high := 0x8080808080808080808080808080808080808080808080808080808080808080
                if and(x, high) { leave }
                let digits :=
                    and(
                        add(x, 0x5050505050505050505050505050505050505050505050505050505050505050),
                        not(add(x, 0x4646464646464646464646464646464646464646464646464646464646464646))
                    )
                let letters :=
                    and(
                        add(x, 0x1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f),
                        not(add(x, 0x1919191919191919191919191919191919191919191919191919191919191919))
                    )
                yes := eq(and(or(digits, letters), high), high)
            }
            let word := mload(add(id, 32))
            let hyphenMask := 0x0000000000000000ff00000000ff00000000ff00000000ff0000000000000000
            let hyphens := 0x00000000000000002d000000002d000000002d000000002d0000000000000000
            // Verify the four separators, then replace them with ASCII zeroes
            // for classification. Extra separators fail the hexadecimal test.
            let separators := eq(and(word, hyphenMask), hyphens)
            word := or(and(word, not(hyphenMask)), 0x0000000000000000300000000030000000003000000000300000000000000000)
            // Only the high four bytes of the second word belong to the UUID.
            // Fill its padding with ASCII zeroes, irrespective of memory contents.
            let tail :=
                or(
                    and(mload(add(id, 64)), 0xffffffff00000000000000000000000000000000000000000000000000000000),
                    0x0000000030303030303030303030303030303030303030303030303030303030
                )
            valid := and(separators, and(hexWord(word), hexWord(tail)))
        }
    }
}
