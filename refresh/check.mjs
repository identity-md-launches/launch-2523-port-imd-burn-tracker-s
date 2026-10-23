#!/usr/bin/env node
// Offline component checks. Every HTTP response below is a synthetic fixture,
// never a replacement for the live comparison documented in PORT.md.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { keccak256, selector, namehash } from './keccak.mjs';
import { DATA_FILES, refreshData, publish, main, round, serialize, decodeUtf8Ignore } from './refresh.mjs';

assert.equal(keccak256(''), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
assert.equal(selector('transfer(address,uint256)'), '0xa9059cbb');
assert.equal(namehash('vitalik.eth'), 'ee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835');
assert.equal(keccak256('abc'), '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
assert.equal(namehash(''), '00'.repeat(32));
assert.equal(namehash('eth'), '93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae');
for (const [n, expected] of [
  [135, 'cbdfd9dee5faad3818d6b06f95a219fd290b0e1706f6a82e5a595b9ce9faca62'],
  [136, '7ce759f1ab7f9ce437719970c26b0a66ff11fe3e38e17df89cf5d29c7d7f807e'],
  [137, 'ac73d4fae68b8453f764007c1a20ce95994187861f0c3227a3a8e99a73a3b1db'],
  [272, 'fdf2ec49e749960d3c8521a0219af8d03e30e2b3bf19bd16150ee0eaf133d66e'],
]) assert.equal(keccak256(Uint8Array.from({length: n}, (_, i) => i % 256)), expected);
assert.equal(decodeUtf8Ignore(Buffer.from([0xff, 0x61, 0xc0, 0xaf, 0xef, 0xbf, 0xbd, 0xe2, 0x82])), 'a\ufffd');
assert.equal(round(2.675, 2), 2.67);
assert.equal(round(1.2345665), 1.234566);
assert.equal(round(1.2345675), 1.234568);
assert.equal(round(-2.675, 2), -2.67);
assert.equal(serialize({amount: 0, rank: 1, volume_eth: 0.000001}), '{\n "amount": 0.0,\n "rank": 1,\n "volume_eth": 1e-06\n}');

const tmp = await mkdtemp(path.join(os.tmpdir(), 'imd-port-check-'));
const FP = '0xff0c532fdb8cd566ae169c1cb157ff2bdc83e105', ETH = '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7';
const X = ['0x2ec59bed2fb9dee447bbec6e3bca249782c9b88b', '0xe29386719c155b6847ad5a4e97c6674f10ffc750'];
const addr = n => '0x' + n.toString(16).padStart(40, '0');
const hex = n => '0x' + n.toString(16), word = n => BigInt(n).toString(16).padStart(64, '0');
const wei = n => BigInt(n) * 10n ** 18n, value = n => '0x' + word(wei(n));
const padded = a => '0x' + a.slice(2).padStart(64, '0');
const txLabels = new Map();
function txid(label) { const hash = '0x' + keccak256('fixture:' + label); txLabels.set(hash, label); return hash; }
const receiver = addr(10), adapter = addr(11), keeper = addr(12), resolver = addr(13), wallet = addr(14), token = addr(15), burner = addr(16), named = addr(17);
const pool = '0x000000000004444c5dc75cb358380d2e3de08a90';
const DAY = '2026-10-22', TS = Date.parse(DAY + 'T12:00:00Z') / 1000, BASE_HEAD = Math.floor((TS - 1686789347) / 2);
const bridgeTopic = '0x' + keccak256('TokensBridgedForBurn(address,uint32,bytes32,uint256,uint256,bytes32)');
const transferTopic = '0x' + keccak256('Transfer(address,address,uint256)');
const burnTopic = '0x' + keccak256('ImdBurned(uint256)');
const counts = new Map();
let nonmonotonic = false, wrongRh = false, missingBurnEvents = false, extraInflow = false;
let failure = '', badBatch = false, shortCoins = false, searchFails = false, trackersFail = false, badEns = false, fallbacks = 0, activeLogs = 0, maxActiveLogs = 0;
function transfer(from, amount, tx, method = '') {
  return {from: {hash: from, is_contract: from !== wallet, name: '', ens_domain_name: ''}, to: {hash: X[0]}, total: {value: wei(amount).toString()}, timestamp: DAY + 'T00:00:00Z', transaction_hash: txid(tx), method};
}
const inflows = [transfer(addr(20), 20, 'community'), transfer(pool, 10, 'pool'), transfer(token, 15, 'swarm'), transfer(addr(21), 20, 'named'), transfer(wallet, 35, 'wallet'), transfer(addr(22), 5, 'accrued', '0x9cb568de'), transfer(X[1], 5, 'internal')];
async function rpc(chain, request) {
  const {method, params} = request;
  if (method === 'eth_blockNumber') return hex(chain === 'base_latest' || chain === 'base' ? BASE_HEAD : chain === 'eth' ? 24000000 : 350000);
  if (method === 'eth_getBlockByNumber') return {timestamp: hex(TS)};
  if (method === 'eth_getLogs') {
    assert.equal(params[0].topics[0], transferTopic);
    assert.ok(params[0].topics[2].every(w => w.length === 66));
    activeLogs++; maxActiveLogs = Math.max(maxActiveLogs, activeLogs);
    await new Promise(resolve => setTimeout(resolve, 10));
    activeLogs--;
    return params[0].fromBlock === '0x0' ? [{blockNumber: hex(1), data: value(wrongRh ? 6 : 7)}, {blockNumber: hex(2), data: value(3)}] : [];
  }
  assert.equal(method, 'eth_call');
  const [{to, data}] = params, sig = data.slice(0, 10), a = '0x' + data.slice(-40);
  if (sig === '0x18160ddd') return value(chain.startsWith('base') ? (nonmonotonic && chain === 'base' && parseInt(params[1], 16) < 4000000 ? 8900000 : 9000000) : chain === 'eth' ? 500000 : 100000);
  if (sig === '0x70a08231') {
    let n = 0;
    if (a.endsWith('dead')) n = chain.startsWith('base') ? 90 : chain === 'eth' ? 20 : 7;
    if (a === addr(1)) n = chain.startsWith('base') ? 10 : chain === 'rh' ? 3 : 0;
    if (a === adapter) n = 600000;
    if (a === X[0]) n = 5;
    return value(n);
  }
  if (sig === selector('peers(uint32)')) return padded(adapter);
  if (sig === selector('token()')) return padded(ETH);
  if (sig === selector('baseBurnReceiver()')) return padded(receiver);
  if (sig === '0x0178b8bf') return padded(resolver);
  if (sig === '0x691f3431') {
    const text = Buffer.from(to === resolver ? 'keeper.eth' : '');
    return '0x' + word(32) + word(text.length) + text.toString('hex').padEnd(64, '0');
  }
  if (sig === '0x3b3b57de') return padded(badEns ? addr(999) : keeper);
  throw new Error('unhandled fixture RPC ' + data);
}
const server = createServer(async (req, res) => {
  try {
    const u = new URL(req.url, 'http://localhost');
    counts.set(u.pathname, (counts.get(u.pathname) || 0) + 1);
    if (failure && u.pathname.startsWith(failure)) { res.writeHead(503); res.end('fixture outage'); return; }
    let result;
    if (['/base', '/base_latest', '/eth', '/rh', '/fallback'].includes(u.pathname)) {
      const buffers = []; for await (const b of req) buffers.push(b);
      const body = JSON.parse(Buffer.concat(buffers));
      if (u.pathname === '/fallback') { fallbacks++; res.end(JSON.stringify({error: {message: 'fixture RPC failure'}})); return; }
      const chain = u.pathname.slice(1);
      const one = async r => ({jsonrpc: '2.0', id: r.id, result: await rpc(chain, r)});
      result = Array.isArray(body) ? (await Promise.all(body.map(one))).reverse() : await one(body);
      if (badBatch && Array.isArray(result)) result[0].id = result[1].id;
    } else if (u.pathname === '/blockscout/api/v2/search') {
      if (searchFails) { res.writeHead(503); res.end('fixture optional search outage'); return; }
      result = {items: [{name: 'BurnExecutor', type: 'contract', address_hash: X[0]}, {name: 'Other', type: 'contract', address_hash: addr(99)}]};
    } else if (u.pathname.endsWith('/logs')) {
      const x = u.pathname.split('/')[5], second = u.searchParams.has('page');
      const item = (amount, b, tx) => ({topics: [bridgeTopic, padded(keeper), padded(addr(1)), padded(receiver)], data: value(amount) + word(0) + word(1), block_number: b, transaction_hash: txid(tx)});
      result = x === X[0] ? {items: [item(second ? 40 : 60, second ? 100 : 200, second ? 'bridge1' : 'bridge2'), {topics: [transferTopic]}], next_page_params: second ? null : {page: 2}} : {items: []};
    } else if (u.pathname.endsWith('/token-transfers')) {
      const x = u.pathname.split('/')[5], second = u.searchParams.has('page');
      if (x.toLowerCase().endsWith('dead')) {
        const event = (v, incoming) => ({total: {value: wei(v).toString()}, from: {hash: incoming ? wallet : x}, to: {hash: incoming ? x : wallet}, timestamp: DAY + 'T00:00:00Z'});
        result = {items: [event(second ? 5 : 25, !second)], next_page_params: second ? null : {page: 2}};
      } else result = x === X[0] ? {items: second ? [...inflows.slice(3), ...(extraInflow ? [transfer(wallet, 100, 'extra')] : [])] : inflows.slice(0, 3), next_page_params: second ? null : {page: 2}} : {items: []};
    } else if (u.pathname.startsWith('/blockscout/api/v2/transactions/')) {
      const tx = txLabels.get(u.pathname.split('/').at(-1));
      result = {from: {hash: keeper}, to: {hash: tx === 'swarm' ? burner : tx === 'named' ? named : ETH, name: tx === 'named' ? 'NamedContract' : ''}, value: '1000000000000000', fee: {value: '1000000000000000'}};
    } else if (u.pathname === '/blockscout/api') {
      assert.equal(u.searchParams.get('topic0'), burnTopic);
      result = {result: missingBurnEvents ? [] : [{transactionHash: txid('community')}]};
    } else if (u.pathname.startsWith('/blockscout/api/v2/tokens/')) {
      if (trackersFail || u.pathname.endsWith(addr(30))) { res.writeHead(404); res.end('fixture non-token'); return; }
      result = {name: 'Fixture Token', symbol: 'FIX'};
    } else if (u.pathname === '/launches') {
      const launches = u.searchParams.has('before') ? [] : [
        {launchNumber: 2, chainId: 1, status: 'live', createdAt: DAY, artifacts: [{address: token, name: 'Token', role: 'token'}, {address: burner, name: 'Burner', role: 'hook'}]},
        {launchNumber: 3, chainId: 1, status: 'live', createdAt: DAY, artifacts: [{address: addr(30), name: 'BurnFallback', role: 'hook'}]},
        ...Array.from({length: 498}, (_, i) => ({launchNumber: i + 10, chainId: 137, artifacts: []})),
      ];
      result = {launches};
    } else if (u.pathname === '/graphql') {
      const buffers = []; for await (const b of req) buffers.push(b);
      const {variables} = JSON.parse(Buffer.concat(buffers));
      const second = variables.after !== null;
      const size = shortCoins ? 49 : second ? 1 : 500;
      result = {data: {coins: {items: Array.from({length: size}, (_, i) => ({address: addr(1000 + i), name: 'Coin ' + i, symbol: 'C', creator: wallet, createdAt: String(TS), tradeCount: String(i + 1), volumeEth: '1000000000000', burnedImd: String(wei(i + 1))})), pageInfo: {hasNextPage: !shortCoins && !second, endCursor: second ? null : 'next'}}}};
    } else throw new Error('unhandled fixture URL ' + req.url);
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(result));
  } catch (e) { res.writeHead(500); res.end(String(e.stack)); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const root = `http://127.0.0.1:${server.address().port}`;
const env = {
  IMD_RPC_BASE: root + '/base', IMD_RPC_BASE_LATEST: root + '/base_latest', IMD_RPC_ETH: root + '/eth', IMD_RPC_RH: root + '/rh',
  IMD_BLOCKSCOUT_URL: root + '/blockscout', IMD_LAUNCHES_URL: root + '/launches', IMD_INDEXER_URL: root + '/graphql',
};
const quickRefresh = env => refreshData(env, {pause: async () => {}});
try {
  const data = await quickRefresh({...env, IMD_RPC_ETH: root + '/fallback,' + root + '/eth'});
  assert.ok(fallbacks > 0); assert.equal(maxActiveLogs, 4);
  assert.deepEqual(data['imd-executor-bridges.json'].map(r => r.amount), [40, 60]);
  assert.equal(data['imd-burnkeepers.json'][0].ens, 'keeper.eth');
  assert.equal(data['imd-burnkeepers.json'][0].imd_sent_to_burn, 100);
  assert.equal(data['imd-executor-sources.json'].find(r => r.kind === 'community coins').imd_sent, 25);
  assert.ok(data['imd-executor-sources.json'].some(r => r.source === 'Fixture Token (FIX) #2'));
  assert.ok(data['imd-burn-coins.json'].some(r => r.name === 'BurnFallback #3'));
  assert.equal(data['summary.json'].executor_inflows, 105);
  assert.equal(data['summary.json'].burn_coins, 502);
  assert.equal(data['imd-burn-history.json'].at(-1).base_burned, 1000100);
  assert.deepEqual(Object.keys(data).sort(), [...DATA_FILES].sort());
  const out = path.join(tmp, 'node');
  await publish(out, data);
  const before = Object.fromEntries(await Promise.all(DATA_FILES.map(async f => [f, await readFile(path.join(out, f), 'utf8')])));
  await writeFile(path.join(out, 'imd-refresh-status.json'), JSON.stringify([{last_success_at: '2026-10-20T00:00:00Z', data_as_of: '2026-10-19T23:59:59Z'}]));
  failure = '/base_latest';
  await main(out, env, quickRefresh);
  const status = JSON.parse(await readFile(path.join(out, 'imd-refresh-status.json')))[0];
  assert.equal(status.last_result, 'failed'); assert.match(status.message, /base_latest eth_blockNumber failed.*503/);
  assert.equal(status.last_success_at, '2026-10-20T00:00:00Z'); assert.equal(status.data_as_of, '2026-10-19T23:59:59Z');
  for (const f of DATA_FILES) assert.equal(await readFile(path.join(out, f), 'utf8'), before[f], f + ' changed on outage');
  const emptyOut = path.join(tmp, 'empty-failed');
  await main(emptyOut, env, quickRefresh);
  assert.deepEqual(await readdir(emptyOut), ['imd-refresh-status.json']);
  assert.equal(JSON.parse(await readFile(path.join(emptyOut, 'imd-refresh-status.json')))[0].last_result, 'failed');
  failure = ''; shortCoins = true;
  await main(out, env, quickRefresh);
  assert.match(JSON.parse(await readFile(path.join(out, 'imd-refresh-status.json')))[0].message, /community coins list looks incomplete/);
  for (const f of DATA_FILES) assert.equal(await readFile(path.join(out, f), 'utf8'), before[f], f + ' changed on sanity failure');
  shortCoins = false;
  for (const scenario of ['nonmonotonic', 'wrongRh', 'missingBurnEvents', 'extraInflow']) {
    nonmonotonic = scenario === 'nonmonotonic'; wrongRh = scenario === 'wrongRh';
    missingBurnEvents = scenario === 'missingBurnEvents'; extraInflow = scenario === 'extraInflow';
    const expected = {nonmonotonic: /base history not monotonic/, wrongRh: /rh history .* != burn wallets/, missingBurnEvents: /LaunchpadHook burn events missing/, extraInflow: /executor inflows .* vs bridged\+waiting/}[scenario];
    await assert.rejects(quickRefresh(env), expected);
  }
  nonmonotonic = false; wrongRh = false; missingBurnEvents = false; extraInflow = false;
  badBatch = true;
  await assert.rejects(quickRefresh(env), /base history chunk 0 failed.*invalid batch IDs/);
  badBatch = false;
  searchFails = true; trackersFail = true; badEns = true;
  const fallbackData = await quickRefresh(env);
  assert.equal(fallbackData['imd-burnkeepers.json'][0].ens, '');
  assert.ok(fallbackData['imd-executor-sources.json'].some(r => r.source === 'Burner #2'));
  searchFails = false; trackersFail = false; badEns = false;
  // Staging/serialization failure leaves the entire prior dataset alone.
  await assert.rejects(publish(out, {...data, 'imd-supply.json': [{supply_now: NaN}]}), /non-finite/);
  for (const f of DATA_FILES) assert.equal(await readFile(path.join(out, f), 'utf8'), before[f]);
  assert.ok(!(await readdir(out)).some(f => f.startsWith('.imd-')));
  await main(out, env, quickRefresh);
  assert.equal(JSON.parse(await readFile(path.join(out, 'imd-refresh-status.json')))[0].last_result, 'refreshed');

  if (process.argv.includes('--python')) {
    // Run the UNMODIFIED Python reference via runpy. Only transport and sleeps
    // are substituted, so both versions consume exactly the same HTTP fixtures.
    const bootstrap = path.join(tmp, 'reference.py');
    await writeFile(bootstrap, `import sys,urllib.request,time,runpy\nroot=sys.argv[1]\nout=sys.argv[2]\noriginal=urllib.request.urlopen\ndef redirected(req,*args,**kwargs):\n url=req.full_url\n routes=[('https://base-mainnet.public.blastapi.io','/base'),('https://mainnet.base.org','/base'),('https://base.gateway.tenderly.co','/base'),('https://base-rpc.publicnode.com','/base_latest'),('https://ethereum-rpc.publicnode.com','/eth'),('https://rpc.mainnet.chain.robinhood.com','/rh'),('https://eth.blockscout.com','/blockscout'),('https://api.imd.fun/launches','/launches'),('https://imd-communitycoins-indexer.up.railway.app/graphql','/graphql')]\n for prefix,target in routes:\n  if url.startswith(prefix):\n   req=urllib.request.Request(root+target+url[len(prefix):],data=req.data,headers=dict(req.header_items()),method=req.get_method())\n   return original(req,*args,**kwargs)\n raise RuntimeError('unexpected upstream '+url)\nurllib.request.urlopen=redirected\ntime.sleep=lambda _:None\nsys.argv=['refresh/refresh_imd.py',out]\nrunpy.run_path('refresh/refresh_imd.py',run_name='__main__')\n`);
    // Differential rounding on deterministic values near the dashboard's range.
    let seed = 123456789;
    const samples = [2.675, -2.675, 1.005, 0.0000005, -0.0000005, 9999999.9999995];
    for (let i = 0; i < 1000; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      samples.push((seed / 2 ** 32 - 0.5) * 10 ** (i % 8));
    }
    const expected = await new Promise((resolve, reject) => {
      const child = spawn('python3', ['-c', 'import sys,json; x=json.load(sys.stdin); print(json.dumps([[round(v,2),round(v,6)] for v in x]))'], {stdio: ['pipe', 'pipe', 'pipe']});
      let output = '', errors = '';
      child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { errors += b; });
      child.on('error', reject); child.on('exit', code => code === 0 ? resolve(JSON.parse(output)) : reject(new Error(errors)));
      child.stdin.end(JSON.stringify(samples));
    });
    samples.forEach((v, i) => assert.deepEqual([round(v, 2), round(v, 6)], expected[i], 'Python rounding: ' + v));
    console.log('PASS: 1,006 differential Python rounding cases at two and six decimals');
    const pythonOut = path.join(tmp, 'python');
    await new Promise((resolve, reject) => {
      const child = spawn('python3', [bootstrap, root, pythonOut], {stdio: ['ignore', 'pipe', 'pipe']});
      let output = ''; child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
      child.on('error', reject); child.on('exit', code => code === 0 ? resolve() : reject(new Error('Python reference failed: ' + output)));
    });
    for (const f of DATA_FILES) {
      const reference = await readFile(path.join(pythonOut, f), 'utf8');
      assert.deepEqual(JSON.parse(before[f]), JSON.parse(reference), 'Python semantic parity: ' + f);
      assert.equal(before[f], reference, 'Python byte parity: ' + f);
    }
    console.log('PASS: all ten fixture outputs match unmodified Python byte for byte');
  }
  console.log('PASS: Keccak, rounding, pagination, batch IDs/order, four workers, classification, ENS confirmation/fallbacks, deduplication, status, sanity rejection and preservation');
} finally {
  await new Promise(resolve => server.close(resolve));
  await rm(tmp, {recursive: true, force: true});
}
