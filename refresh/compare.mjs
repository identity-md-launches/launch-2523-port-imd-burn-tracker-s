#!/usr/bin/env node
// Compare sequential live runs. Reports differences; does not hide chain drift.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { DATA_FILES } from './refresh.mjs';

const [left, right] = process.argv.slice(2);
if (!left || !right) {
  console.error('Usage: node refresh/compare.mjs NODE_OUT PYTHON_OUT');
  process.exitCode = 1;
} else {
  const rows = [], differences = [];
  let structureMatches = true, numericCount = 0, otherCount = 0;
  function compare(a, b, at, diffs) {
    if (typeof a !== typeof b || (a === null) !== (b === null) || Array.isArray(a) !== Array.isArray(b)) {
      diffs.push({at, a, b, kind: 'type'}); structureMatches = false; return;
    }
    if (typeof a === 'number') {
      if (a !== b) { diffs.push({at, a, b, delta: b - a, kind: 'number'}); numericCount++; }
    } else if (a && typeof a === 'object') {
      const ka = Object.keys(a), kb = Object.keys(b);
      if (JSON.stringify(ka) !== JSON.stringify(kb)) {
        diffs.push({at, a: ka, b: kb, kind: 'keys/order'}); structureMatches = false;
      }
      for (const k of ka) if (Object.hasOwn(b, k)) compare(a[k], b[k], at + (Array.isArray(a) ? `[${k}]` : '.' + k), diffs);
    } else if (a !== b) { diffs.push({at, a, b, kind: 'value'}); otherCount++; }
  }
  for (const file of DATA_FILES) {
    try {
      const [la, rb] = await Promise.all([readFile(path.join(left, file), 'utf8'), readFile(path.join(right, file), 'utf8')]);
      const a = JSON.parse(la), b = JSON.parse(rb), diffs = [];
      compare(a, b, file, diffs);
      rows.push(`| ${file} | ${Array.isArray(a) ? a.length : 'object'} | ${Array.isArray(b) ? b.length : 'object'} | ${diffs.length} | ${la === rb ? 'yes' : 'no'} |`);
      differences.push(...diffs);
    } catch (e) { rows.push(`| ${file} | missing/unreadable | missing/unreadable | — | no |`); differences.push({at: file, kind: 'read error', message: e.message}); structureMatches = false; }
  }
  console.log('| File | Node rows | Python rows | Different values | Byte equal |\n| --- | ---: | ---: | ---: | --- |\n' + rows.join('\n'));
  console.log(`\nAll ten files readable with identical keys, key order and row counts: ${structureMatches ? 'yes' : 'NO'}. Numeric differences: ${numericCount}; other value differences: ${otherCount}.`);
  if (differences.length) {
    console.log('\nComplete difference list (delta = Python minus Node):\n\n```json\n' + JSON.stringify(differences, null, 2) + '\n```');
  }
  if (!structureMatches) process.exitCode = 1;
}
