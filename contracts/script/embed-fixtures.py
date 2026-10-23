#!/usr/bin/env python3
"""Verify and embed exact, previously downloaded result bytes. Never contacts the network."""

import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "test" / "fixtures"
rows = json.loads((FIXTURES / "provenance.json").read_text())
source = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Exact downloaded bytes, embedded so tests need no filesystem permissions or network.
// Regenerate with script/embed-fixtures.py; provenance.json records on-chain hashes and sources.
library RealResults {
"""
source += f"    function count() internal pure returns (uint256) {{ return {len(rows)}; }}\n"
source += "    function get(uint256 index) internal pure returns (bytes memory document, bytes32 hash, string memory jobId) {\n"
for index, row in enumerate(rows):
    document = (FIXTURES / row["file"]).read_bytes()
    parsed = json.loads(document)
    digest = subprocess.check_output(["cast", "keccak", "0x" + document.hex()], text=True).strip()
    assert len(document) == row["bytes"], row["file"]
    assert digest == row["resultHash"], row["file"]
    assert parsed["jobId"] == row["jobId"] and parsed["state"] == "completed", row["file"]
    assert json.dumps(parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() == document
    source += (
        f'        if (index == {index}) return (hex"{document.hex()}", '
        f'{digest}, "{row["jobId"]}");\n'
    )
source += '        revert("unknown fixture");\n    }\n}\n'
(ROOT / "test" / "helpers" / "RealResults.sol").write_text(source)
print(f"Verified and embedded {len(rows)} original result documents; run forge fmt afterward.")
