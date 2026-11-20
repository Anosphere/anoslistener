#!/usr/bin/env node
/**
 * verify-garlic-chain.mjs
 *
 * Checks one validator's database: the garlic_chain table, the accounts
 * table and the stakes table, against each other and against the signatures
 * the links carry. It only reads. Everything is read inside one read-only
 * transaction, so the three tables are seen as they stood at one moment,
 * even while the validator keeps writing.
 *
 * Run it on the worker VM:
 *
 *   sudo -iu anos node /tmp/verify-garlic-chain.mjs
 *
 * Nothing is installed for it. It takes `pg` and `canonicalize` from the
 * validator's own node_modules, and the database settings from the
 * validator's own two files, network/testnet.env and .env, all in
 * /opt/anos/anossoftware. Another folder is given with --repo <folder>. A
 * PG variable that is set in the environment (PGHOST, PGPORT, PGUSER,
 * PGPASSWORD, PGDATABASE) wins over the two files.
 *
 * The last line is EVERYTHING IS PERFECT or PROBLEMS FOUND, and the exit
 * code is 0 or 1. Exit code 2 means the check itself could not run.
 *
 * What is checked, link by link, from the first to the last:
 *   - the positions count up from 1 and none is missing;
 *   - trans_hash is the SHA-256 of the canonical JSON of the signed
 *     transaction (og_transaction.payload);
 *   - record_hash is the SHA-256 of trans_hash followed by the record_hash
 *     of the link before it;
 *   - every signature: the eight of an account creation, by the eight keys
 *     it names; those of a transfer, a stake and a fund proposal, by the
 *     keys the signing account was created with, under the validator's
 *     rule (any two of the three key pairs; the break-glass pair alone for
 *     a break-glass transfer);
 *   - the ids: an account's id and an account creation's transaction id are
 *     the hashes of its keys; every other transaction id is the hash of the
 *     transaction without it; a payout link is exactly the payout of the
 *     fund proposal before it, and a proposal is followed by all its
 *     payouts;
 *   - the row's columns (type, account_id, account_id_to, transaction_id,
 *     amount) say what the signed transaction says;
 *   - the rules a validator checks before it takes a transaction in, which
 *     must still hold on the chain: the sender and the receiver exist and
 *     differ, the sender's account type fits the transfer type, a transfer
 *     names the sender's transaction before it, no balance goes below
 *     zero, and a guarded or vault transfer was written after its date.
 * Then the accounts table: every row was created by a link and every
 * creation has its row; the eight keys and the type are the creation's; the
 * balance is the genesis amount plus what the links moved in, minus what
 * they moved out. Then the stakes table, the same way.
 *
 * The genesis, as the validator's src/genesis/genesis.service.js writes it:
 * the first two links create the fund (200,000,000 anos) and the first
 * account (10,000,000 anos). Every other account starts at 0.
 *
 * This file is kept beside the repositories, in anossoftwarescripts/. It is
 * not part of the validator's repository. verify-garlic-chain-paste.txt,
 * beside it, carries it to a worker in one paste: this file packed as text,
 * a checksum of this file, and the line that runs it. Make the paste file
 * again after any change here, or its checksum stops the run. The packed
 * text is made on the Mac with
 *
 *   gzip -9 -n -c verify-garlic-chain.mjs | base64 -b 76
 *
 * and unpacked on the worker between these two lines:
 *
 *   base64 -d <<'EOF' | gunzip > /tmp/verify-garlic-chain.mjs
 *   EOF
 */

import { createHash, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs, parseEnv } from 'node:util';

// ---------------------------------------------------------------------------
// The fixed facts of the chain.
// ---------------------------------------------------------------------------

/** Where the validator is installed on a worker VM. */
const DEFAULT_REPO = '/opt/anos/anossoftware';

/** Links and account rows read per round trip, and how many accounts' keys are kept in memory at once. */
const LINKS_PER_PAGE = 100;
const ACCOUNTS_PER_PAGE = 200;
const KEYS_KEPT = 1000;

/** How many problems are printed. The count printed is always the whole count. */
const PROBLEMS_SHOWN = 200;

/** Amounts are whole numbers of millionths of an anos. */
const MILLIONTHS_PER_ANOS = 1_000_000n;

/** The genesis balances (src/genesis/genesis.service.js). */
const FUND_GENESIS_BALANCE = 200_000_000n * MILLIONTHS_PER_ANOS;
const FIRST_ACCOUNT_GENESIS_BALANCE = 10_000_000n * MILLIONTHS_PER_ANOS;

/** The largest value a BIGINT column holds. */
const MAX_BIGINT = 2n ** 63n - 1n;

const P256 = 'P-256';
const ML_DSA_87 = 'ML-DSA-87';

/**
 * The eight keys of an account, in the order an account creation's
 * transaction id hashes them, each with the accounts column that holds it.
 */
const ACCOUNT_KEYS = [
  { name: 'key1', algorithm: P256, column: 'public_key1' },
  { name: 'postQuantumKey1', algorithm: ML_DSA_87, column: 'public_key_pq1' },
  { name: 'key2', algorithm: P256, column: 'public_key2' },
  { name: 'postQuantumKey2', algorithm: ML_DSA_87, column: 'public_key_pq2' },
  { name: 'breakGlassKey', algorithm: P256, column: 'break_glass_pk' },
  { name: 'breakGlassPostQuantumKey', algorithm: ML_DSA_87, column: 'break_glass_pk_pq' },
  { name: 'walletKey', algorithm: P256, column: 'alt_wallet_pk' },
  { name: 'walletPostQuantumKey', algorithm: ML_DSA_87, column: 'alt_wallet_pk_pq' },
];
const ALGORITHM_OF = new Map(ACCOUNT_KEYS.map(({ name, algorithm }) => [name, algorithm]));

/** The three pairs that sign for an account, and the break-glass pair. */
const SIGNING_PAIRS = [
  ['key1', 'postQuantumKey1'],
  ['key2', 'postQuantumKey2'],
  ['walletKey', 'walletPostQuantumKey'],
];
const BREAK_GLASS_PAIR = ['breakGlassKey', 'breakGlassPostQuantumKey'];

const ANY_TWO_PAIRS = 'any two pairs';
const BREAK_GLASS_ALONE = 'the break-glass pair alone';

const SPENDING = 'spending';
const GUARDED = 'guarded';
const VAULT = 'vault';
const ASSISTED = 'assisted';
const FUND = 'fund';
const ACCOUNT_TYPES = [SPENDING, GUARDED, VAULT, ASSISTED];

const ACCOUNT_CREATION = 'accountCreation';
const BREAK_GLASS_TRANSFER = 'breakGlassTransfer';
const TRANSFER_TO_FUND = 'transferToFund';
const FUND_PROPOSAL = 'fundProposal';
const TRANSFER_FROM_FUND = 'transferFromFund';

/** The six transfer types: the one account type each may leave (null: any), and its signing rule. */
const TRANSFER_TYPES = new Map([
  ['anosTransfer', { from: SPENDING, rule: ANY_TWO_PAIRS }],
  ['guardedAnosTransfer', { from: GUARDED, rule: ANY_TWO_PAIRS }],
  ['vaultAnosTransfer', { from: VAULT, rule: ANY_TWO_PAIRS }],
  ['assistedAnosTransfer', { from: ASSISTED, rule: ANY_TWO_PAIRS }],
  ['escrowTransfer', { from: SPENDING, rule: ANY_TWO_PAIRS }],
  [BREAK_GLASS_TRANSFER, { from: null, rule: BREAK_GLASS_ALONE }],
]);

/** The link types whose amount the database moves from account_id to account_id_to (the trigger in db/schema.sql). */
const MOVES_ANOS = new Set([...TRANSFER_TYPES.keys(), TRANSFER_TO_FUND, TRANSFER_FROM_FUND]);

/** The six stake purposes, each with its stakes column. */
const STAKE_COLUMNS = new Map([
  ['daoVote', 'dao_vote_stake'],
  ['moderator', 'moderator_stake'],
  ['attestor', 'attestor_stake'],
  ['guardian', 'guardian_stake'],
  ['validator', 'validator_stake'],
  ['masterPod', 'master_pod_stake'],
]);

// ---------------------------------------------------------------------------
// Small helpers.
// ---------------------------------------------------------------------------

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** SHA-256 as a 32-byte Buffer. A string is hashed as its UTF-8 bytes. */
function sha256(data) {
  return createHash('sha256').update(data).digest();
}

/** The fund's account id: the SHA-256 of the word "anosFund". */
const FUND_ACCOUNT_ID = sha256('anosFund');

/**
 * Decodes bytes that travel as a string, the way the validator does: hex
 * first, then base64 or base64url, keeping the result only when its length
 * is right. Null for anything else.
 */
function decodeBytes(encoded, lengthIsRight) {
  if (typeof encoded !== 'string' || encoded.length === 0) return null;
  if (encoded.length % 2 === 0 && /^[0-9a-f]+$/i.test(encoded)) {
    const bytes = Buffer.from(encoded, 'hex');
    if (lengthIsRight(bytes.length)) return bytes;
  }
  if (/^[A-Za-z0-9+/_-]+={0,2}$/.test(encoded)) {
    const bytes = Buffer.from(encoded, 'base64');
    if (lengthIsRight(bytes.length)) return bytes;
  }
  return null;
}

/** A SHA-256 digest from its string, or null. */
function decodeDigest(encoded) {
  return decodeBytes(encoded, (length) => length === 32);
}

/** An amount from a signed transaction as a BigInt, or null when it is not a positive whole number that fits a BIGINT. */
function parseAmount(amount) {
  if (typeof amount !== 'string' || !/^[1-9][0-9]*$/.test(amount)) return null;
  const value = BigInt(amount);
  return value > MAX_BIGINT ? null : value;
}

function hex(bytes) {
  return bytes.toString('hex');
}

/** A value for a message: quoted text, or the word for nothing. */
function show(value) {
  return value === undefined ? 'nothing' : JSON.stringify(value);
}

function showId(bytes) {
  return bytes === null ? 'nothing' : hex(bytes);
}

/** Millionths as anos, for example 1,234.5 anos. */
function anos(millionths) {
  const negative = millionths < 0n;
  const absolute = negative ? -millionths : millionths;
  const whole = (absolute / MILLIONTHS_PER_ANOS).toLocaleString('en-US');
  const fraction = (absolute % MILLIONTHS_PER_ANOS).toString().padStart(6, '0').replace(/0+$/, '');
  return `${negative ? '-' : ''}${whole}${fraction === '' ? '' : `.${fraction}`} anos`;
}

function count(number) {
  return number.toLocaleString('en-US');
}

// ---------------------------------------------------------------------------
// Signatures: classical ECDSA on P-256 and post-quantum ML-DSA-87, both
// built into Node 24. A public key travels as raw bytes; Node takes it as
// SubjectPublicKeyInfo DER, which for a fixed algorithm and key length is a
// constant prefix in front of the raw bytes. selfTest() proves the prefixes
// on this Node before anything is judged with them.
// ---------------------------------------------------------------------------

const P256_SPKI_PREFIX = {
  33: Buffer.from('3039301306072a8648ce3d020106082a8648ce3d030107032200', 'hex'),
  65: Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200', 'hex'),
};
const ML_DSA_87_SPKI_PREFIX = Buffer.from('30820a32300b060960864801650304031303820a2100', 'hex');

const ALGORITHMS = {
  [P256]: {
    keyLengthIsRight: (length) => length === 33 || length === 65,
    // 64 bytes is r || s. A DER signature is normally 70 to 72 bytes.
    signatureLengthIsRight: (length) => length === 64 || (length >= 8 && length <= 72),
    spkiPrefix: (length) => P256_SPKI_PREFIX[length],
    // ECDSA signs the SHA-256 of the message; the message itself is passed in.
    verify: (key, message, signature) =>
      verify('sha256', message, { key, dsaEncoding: signature.length === 64 ? 'ieee-p1363' : 'der' }, signature),
  },
  [ML_DSA_87]: {
    keyLengthIsRight: (length) => length === 2592,
    signatureLengthIsRight: (length) => length === 4627,
    spkiPrefix: () => ML_DSA_87_SPKI_PREFIX,
    // The pure variant: the message itself, no pre-hash, an empty context.
    verify: (key, message, signature) => verify(null, message, key, signature),
  },
};

/** A public key from its string, or null when it is not a key of this algorithm. */
function decodePublicKey(algorithm, encoded) {
  return decodeBytes(encoded, ALGORITHMS[algorithm].keyLengthIsRight);
}

/** Node's key object for a raw public key, made once per key. */
const keyObjects = new WeakMap();
function keyObject(algorithm, rawKey) {
  let object = keyObjects.get(rawKey);
  if (!object) {
    const prefix = ALGORITHMS[algorithm].spkiPrefix(rawKey.length);
    object = createPublicKey({ key: Buffer.concat([prefix, rawKey]), format: 'der', type: 'spki' });
    keyObjects.set(rawKey, object);
  }
  return object;
}

/**
 * Checks signatures.<name>, `encoded` as the link carries it, by `rawKey`
 * over `message`. Returns null when it verifies, else the sentence that
 * says what is wrong with it; `whose` names the key it must verify against.
 */
function signatureFault(name, algorithm, rawKey, message, encoded, whose) {
  if (encoded === undefined) return `signatures.${name} is missing`;
  const signature = decodeBytes(encoded, ALGORITHMS[algorithm].signatureLengthIsRight);
  if (!signature) return `signatures.${name} is not a ${algorithm} signature`;
  let good = false;
  try {
    good = ALGORITHMS[algorithm].verify(keyObject(algorithm, rawKey), message, signature);
  } catch {
    good = false;
  }
  return good ? null : `signatures.${name} does not verify against ${whose}`;
}

/**
 * Proves, with keys made on the spot, that this Node verifies both
 * algorithms from raw keys the way the validator does, and that it refuses
 * a changed message. Throws when it does not, so that a Node without
 * ML-DSA-87 can never report good signatures as bad.
 */
function selfTest() {
  const message = Buffer.from('verify-garlic-chain self-test', 'utf8');
  const changed = Buffer.from('verify-garlic-chain self-test.', 'utf8');

  const postQuantum = generateKeyPairSync('ml-dsa-87');
  const postQuantumSpki = postQuantum.publicKey.export({ format: 'der', type: 'spki' });
  const postQuantumRaw = postQuantumSpki.subarray(ML_DSA_87_SPKI_PREFIX.length);
  const postQuantumSignature = sign(null, message, postQuantum.privateKey).toString('hex');
  if (
    !postQuantumSpki.subarray(0, ML_DSA_87_SPKI_PREFIX.length).equals(ML_DSA_87_SPKI_PREFIX) ||
    postQuantumRaw.length !== 2592 ||
    signatureFault('test', ML_DSA_87, postQuantumRaw, message, postQuantumSignature, 'the test key') !== null ||
    signatureFault('test', ML_DSA_87, postQuantumRaw, changed, postQuantumSignature, 'the test key') === null
  ) {
    throw new Error('the ML-DSA-87 self-test failed');
  }

  const classical = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const { x, y } = classical.publicKey.export({ format: 'jwk' });
  const xBytes = Buffer.from(x, 'base64url');
  const yBytes = Buffer.from(y, 'base64url');
  const compressed = Buffer.concat([Buffer.from([2 + (yBytes[31] & 1)]), xBytes]);
  const uncompressed = Buffer.concat([Buffer.from([4]), xBytes, yBytes]);
  const classicalSignature = sign('sha256', message, { key: classical.privateKey, dsaEncoding: 'ieee-p1363' }).toString('hex');
  for (const raw of [compressed, uncompressed]) {
    if (
      signatureFault('test', P256, raw, message, classicalSignature, 'the test key') !== null ||
      signatureFault('test', P256, raw, changed, classicalSignature, 'the test key') === null
    ) {
      throw new Error('the P-256 self-test failed');
    }
  }
}

// ---------------------------------------------------------------------------
// What the check found, and what the links add up to so far.
// ---------------------------------------------------------------------------

const problems = [];
let problemCount = 0;

function problem(text) {
  problemCount += 1;
  if (problems.length < PROBLEMS_SHOWN) problems.push(text);
}

const counts = {
  links: 0,
  byType: new Map(),
  signatures: 0,
  firstPosition: null,
  accountRows: 0,
  accountsByType: new Map(),
  fundBalance: null,
  stakeRows: 0,
  stakedFor: new Map(),
};

/** Every account the links created so far: id (hex) -> { type, balance, latestTransactionId, position, keysDigest, inTable }. */
const accounts = new Map();

/** The stakes the links add up to so far: id (hex) -> { daoVote, moderator, attestor, guardian, validator, masterPod }, in millionths. */
const stakes = new Map();

/** The fund proposal whose payout links are due next: { payload, nextIndex, position }, or null. */
let openProposal = null;

/** The link before the one being checked: { position, recordHash }, or null before the first. */
let previousLink = null;

/** Whether one of the first two links created the fund account. */
let fundCreatedByGenesis = false;

/** The decoded keys of the accounts used last: id (hex) -> { key1: Buffer or null, ... }. */
const keyCache = new Map();

/** The database connection and the canonical JSON function, set by main(). */
let db;
let canonicalize;

/** The SHA-256 of the canonical JSON of a transaction without its transactionId: how every id but an account creation's is made. */
function unsignedHash(payload) {
  const unsigned = { ...payload };
  delete unsigned.transactionId;
  return sha256(canonicalize(unsigned));
}

/** The eight keys of an account creation, decoded: { key1: Buffer or null, ... }. */
function decodeKeys(publicKeys) {
  const keys = {};
  for (const { name, algorithm } of ACCOUNT_KEYS) {
    keys[name] = isObject(publicKeys) ? decodePublicKey(algorithm, publicKeys[name]) : null;
  }
  return keys;
}

/** One hash over eight keys in ACCOUNT_KEYS order (Buffers or nulls), to compare an account row with its creation. */
function digestOfKeys(keysInOrder) {
  const hash = createHash('sha256');
  for (const key of keysInOrder) {
    const length = Buffer.alloc(4);
    length.writeInt32BE(key === null ? -1 : key.length);
    hash.update(length);
    if (key !== null) hash.update(key);
  }
  return hash.digest();
}

function rememberKeys(id, keys) {
  keyCache.delete(id);
  keyCache.set(id, keys);
  if (keyCache.size > KEYS_KEPT) keyCache.delete(keyCache.keys().next().value);
}

/** The keys account `id` was created with, from memory or from its creation link. */
async function keysOf(id) {
  const kept = keyCache.get(id);
  if (kept) {
    rememberKeys(id, kept);
    return kept;
  }
  const { rows } = await db.query(
    "SELECT og_transaction #> '{payload,publicKeys}' AS public_keys FROM garlic_chain WHERE position = $1",
    [accounts.get(id).position],
  );
  const keys = decodeKeys(rows.length === 1 ? rows[0].public_keys : null);
  rememberKeys(id, keys);
  return keys;
}

// ---------------------------------------------------------------------------
// The signatures of an account over a transaction, under the validator's
// two rules (src/accounts/account-signatures.js).
// ---------------------------------------------------------------------------

/**
 * One pair: both signatures there, each by a key the account has, each
 * verifying over `message`. Says what is wrong; returns true when the pair
 * is good.
 */
function checkPair(pair, keys, signatures, message, say) {
  let good = true;
  for (const name of pair) {
    const algorithm = ALGORITHM_OF.get(name);
    if (signatures[name] === undefined) {
      say(`signatures.${pair[0]} and signatures.${pair[1]} must both be there, and signatures.${name} is not`);
      good = false;
    } else if (keys[name] === null) {
      say(`signatures.${name} is there, and the signing account has no ${name}`);
      good = false;
    } else {
      counts.signatures += 1;
      const fault = signatureFault(name, algorithm, keys[name], message, signatures[name], `the signing account's ${name}`);
      if (fault) {
        say(fault);
        good = false;
      }
    }
  }
  return good;
}

/** The signatures of a transfer, a stake or a fund proposal, by the account with `keys`, under `rule`. */
function checkAccountSignatures(keys, signatures, message, rule, say) {
  if (!isObject(signatures)) {
    say('it carries no signatures');
    return;
  }
  let goodPairs = 0;
  let badPairs = 0;
  for (const pair of SIGNING_PAIRS) {
    if (pair.every((name) => signatures[name] === undefined)) continue;
    if (rule === BREAK_GLASS_ALONE) {
      say(`a break-glass transfer is signed by the break-glass pair alone, and signatures.${pair[0]} or signatures.${pair[1]} is there`);
      badPairs += 1;
    } else if (checkPair(pair, keys, signatures, message, say)) {
      goodPairs += 1;
    } else {
      badPairs += 1;
    }
  }
  if (rule === BREAK_GLASS_ALONE) {
    checkPair(BREAK_GLASS_PAIR, keys, signatures, message, say);
  } else if (badPairs === 0 && goodPairs < 2) {
    say('it is signed by fewer than two of the key pairs key1, key2 and walletKey');
  }
}

// ---------------------------------------------------------------------------
// The stakes the links add up to (src/stakes/stakes.queries.js).
// ---------------------------------------------------------------------------

function emptyStake() {
  return Object.fromEntries([...STAKE_COLUMNS.keys()].map((purpose) => [purpose, 0n]));
}

function addStake(id, purpose, amount) {
  const stake = stakes.get(id) ?? emptyStake();
  stake[purpose] += amount;
  stakes.set(id, stake);
}

function subtractStake(id, purpose, amount, say) {
  const stake = stakes.get(id) ?? emptyStake();
  if (stake[purpose] < amount) {
    say(`it returns ${anos(amount)} of ${purpose} stake to account ${id}, which has ${anos(stake[purpose])} staked for it`);
  }
  stake[purpose] -= amount;
  if (Object.values(stake).every((value) => value === 0n)) stakes.delete(id);
  else stakes.set(id, stake);
}

/** A break-glass transfer moves the sender's whole stakes row to the receiver. */
function moveStake(fromId, toId) {
  const from = stakes.get(fromId);
  if (!from) return;
  const to = stakes.get(toId) ?? emptyStake();
  for (const purpose of STAKE_COLUMNS.keys()) to[purpose] += from[purpose];
  stakes.set(toId, to);
  stakes.delete(fromId);
}

// ---------------------------------------------------------------------------
// One link.
// ---------------------------------------------------------------------------

/** The link SELECT, a page at a time in position order. */
const LINKS_SQL = `
  SELECT position, account_id, account_id_to, transaction_id, amount, trans_hash, record_hash, type,
         created_at, og_transaction
  FROM garlic_chain
  WHERE $1::bigint IS NULL OR position > $1
  ORDER BY position
  LIMIT $2`;

async function checkLink(row) {
  const position = Number(row.position);
  const index = counts.links;
  counts.links += 1;
  counts.byType.set(row.type, (counts.byType.get(row.type) ?? 0) + 1);
  if (counts.firstPosition === null) counts.firstPosition = position;
  const say = (text) => problem(`link ${position} (${row.type}): ${text}`);

  // The record hash. It is chained on the hashes as they are stored, so one
  // bad link is reported once and not again on every link after it.
  const chained = sha256(previousLink === null ? row.trans_hash : Buffer.concat([row.trans_hash, previousLink.recordHash]));
  const hashChains = row.record_hash !== null && chained.equals(row.record_hash);

  // The position. A number can be skipped without a link being lost (the
  // database hands a number out and the write is then taken back); the
  // record hash tells the two apart.
  if (previousLink === null) {
    if (position !== 1) say('the chain starts here and not at position 1');
  } else if (position !== previousLink.position + 1) {
    const missing = count(position - previousLink.position - 1);
    say(
      hashChains
        ? `the link before it has position ${previousLink.position}, so ${missing} position number(s) were skipped. No link was lost there: its record_hash chains on link ${previousLink.position}`
        : `the link before it has position ${previousLink.position}, so ${missing} position(s) are missing between them`,
    );
  }

  if (!hashChains) {
    say(
      previousLink === null
        ? 'record_hash is not the hash of its trans_hash'
        : 'record_hash is not the hash of its trans_hash followed by the record_hash of the link before it',
    );
  }
  previousLink = { position, recordHash: row.record_hash ?? chained };

  const og = row.og_transaction;
  const payload = isObject(og) ? og.payload : undefined;
  const type = isObject(payload) ? payload.transactionType : undefined;

  // A fund proposal is followed by all its payout links before anything else.
  if (openProposal !== null && type !== TRANSFER_FROM_FUND) reportMissingPayouts();

  if (!isObject(payload)) {
    say('og_transaction has no signed transaction (payload) in it');
    moveAnos(row, say);
    noteLatest(row);
    return;
  }

  // The trans hash.
  const canonical = canonicalize(payload);
  if (!sha256(canonical).equals(row.trans_hash)) {
    say('trans_hash is not the hash of the signed transaction (og_transaction.payload)');
  }
  const message = Buffer.from(canonical, 'utf8');

  if (row.type !== type) say(`the type column says ${show(row.type)} and the signed transaction says ${show(type)}`);
  if (index < 2 && type !== ACCOUNT_CREATION) {
    say('the chain starts with the two genesis accounts, and this link does not create an account');
  }

  // The type's own checks, and what its write puts in the row.
  let expected = null;
  if (type === ACCOUNT_CREATION) {
    expected = checkAccountCreation(position, index, og, payload, message, say);
  } else if (TRANSFER_TYPES.has(type) || type === TRANSFER_TO_FUND) {
    expected = await checkTransfer(row, og, payload, message, say);
  } else if (type === FUND_PROPOSAL) {
    expected = await checkFundProposal(position, og, payload, message, say);
  } else if (type === TRANSFER_FROM_FUND) {
    expected = checkPayout(payload, canonical, say);
  } else {
    say(`the signed transaction's type, ${show(type)}, is not one a validator writes`);
  }
  if (expected !== null) compareColumns(row, expected, say);

  moveAnos(row, say);
  noteLatest(row);
}

/**
 * The row's columns against what the signed transaction says. A value left
 * undefined in `expected` was already reported as bad in the transaction
 * itself and is not compared; null means the column holds nothing.
 */
function compareColumns(row, expected, say) {
  for (const [column, wanted] of [
    ['account_id', expected.accountId],
    ['account_id_to', expected.accountIdTo],
    ['transaction_id', expected.transactionId],
  ]) {
    if (wanted === undefined) continue;
    const actual = row[column];
    const same = actual === null || wanted === null ? actual === wanted : actual.equals(wanted);
    if (!same) say(`the ${column} column says ${showId(actual)} and the signed transaction says ${showId(wanted)}`);
  }
  if (expected.amount !== undefined && BigInt(row.amount) !== expected.amount) {
    say(`the amount column says ${row.amount} and the signed transaction says ${expected.amount}`);
  }
}

/**
 * The balances, moved as the database's trigger moves them: by the row's
 * own type, account_id, account_id_to and amount.
 */
function moveAnos(row, say) {
  if (!MOVES_ANOS.has(row.type)) return;
  const amount = BigInt(row.amount);
  const sender = row.account_id === null ? undefined : accounts.get(hex(row.account_id));
  const receiver = row.account_id_to === null ? undefined : accounts.get(hex(row.account_id_to));
  if (!sender) {
    say(`its amount leaves account ${showId(row.account_id)}, which no link created`);
  } else {
    sender.balance -= amount;
    if (sender.balance < 0n) say(`it takes the sender's balance below zero, to ${anos(sender.balance)}`);
  }
  if (!receiver) say(`its amount goes to account ${showId(row.account_id_to)}, which no link created`);
  else receiver.balance += amount;
}

/** An account's latest transaction is its newest link by account_id, as the validator finds it. */
function noteLatest(row) {
  if (row.account_id === null) return;
  const account = accounts.get(hex(row.account_id));
  if (account) account.latestTransactionId = hex(row.transaction_id);
}

function reportMissingPayouts() {
  const { payload, nextIndex, position } = openProposal;
  problem(
    `link ${position} (${FUND_PROPOSAL}): it has ${payload.payouts.length} payout(s) and ${nextIndex} payout link(s) come right after it`,
  );
  openProposal = null;
}

// ---------------------------------------------------------------------------
// The link types.
// ---------------------------------------------------------------------------

/** An account creation: its eight keys, its eight signatures, its two ids, its type. Adds the account. */
function checkAccountCreation(position, index, og, payload, message, say) {
  const expected = { accountId: undefined, accountIdTo: null, transactionId: undefined, amount: 0n };
  const { publicKeys } = payload;
  if (!isObject(publicKeys)) say('the signed transaction has no publicKeys');
  if (!isObject(og.signatures)) say('it carries no signatures');
  const signatures = isObject(og.signatures) ? og.signatures : {};

  // The eight keys, each with its own signature.
  const keys = decodeKeys(publicKeys);
  for (const { name, algorithm } of ACCOUNT_KEYS) {
    if (keys[name] === null) {
      say(`publicKeys.${name} is not a ${algorithm} public key`);
    } else if (isObject(og.signatures)) {
      counts.signatures += 1;
      const fault = signatureFault(name, algorithm, keys[name], message, signatures[name], `publicKeys.${name}`);
      if (fault) say(fault);
    }
  }
  const keyStrings = ACCOUNT_KEYS.map(({ name }) => (isObject(publicKeys) ? publicKeys[name] : undefined));
  const allKeysAreStrings = keyStrings.every((key) => typeof key === 'string');

  // The account id: the hash of key1 and postQuantumKey1 as sent. Not for
  // the fund, whose id is the hash of the word "anosFund".
  const accountId = decodeDigest(payload.accountId);
  const isFund = accountId !== null && accountId.equals(FUND_ACCOUNT_ID);
  if (accountId === null) {
    say('accountId is not a SHA-256 digest');
  } else {
    expected.accountId = accountId;
    if (!isFund && allKeysAreStrings && !sha256(keyStrings[0] + keyStrings[1]).equals(accountId)) {
      say('accountId is not the hash of key1 and postQuantumKey1');
    }
  }

  // The transaction id: the hash of the eight keys as sent, in order.
  const transactionId = decodeDigest(payload.transactionId);
  if (transactionId === null) {
    say('transactionId is not a SHA-256 digest');
  } else {
    expected.transactionId = transactionId;
    if (allKeysAreStrings && !sha256(keyStrings.join('')).equals(transactionId)) {
      say('transactionId is not the hash of the eight public keys');
    }
  }

  // The account type.
  if (isFund) {
    if (payload.accountType !== FUND) say(`the fund's accountType is ${show(payload.accountType)}, not "fund"`);
  } else if (!ACCOUNT_TYPES.includes(payload.accountType)) {
    say(`accountType is ${show(payload.accountType)}, not one of ${ACCOUNT_TYPES.join(', ')}`);
  }

  // The genesis: the first two links, one of them the fund.
  let balance = 0n;
  if (index < 2) balance = isFund ? FUND_GENESIS_BALANCE : FIRST_ACCOUNT_GENESIS_BALANCE;
  if (isFund) {
    if (index < 2) fundCreatedByGenesis = true;
    else say('it creates the fund account, which one of the first two links must create');
  }

  if (accountId !== null) {
    const id = hex(accountId);
    const existing = accounts.get(id);
    if (existing) {
      say(`account ${id} was already created by link ${existing.position}`);
    } else {
      accounts.set(id, {
        type: payload.accountType,
        balance,
        latestTransactionId: null,
        position,
        keysDigest: digestOfKeys(ACCOUNT_KEYS.map(({ name }) => keys[name])),
        inTable: false,
      });
      rememberKeys(id, keys);
    }
  }
  return expected;
}

/**
 * A transfer of any of the six types, or a transferToFund (a stake): the
 * ids, the amount, the sender's signatures, and the rules that must still
 * hold on the chain. A stake grows the sender's stake; a break-glass
 * transfer moves the sender's stakes to the receiver.
 */
async function checkTransfer(row, og, payload, message, say) {
  const type = payload.transactionType;
  const isStake = type === TRANSFER_TO_FUND;
  const { from, rule } = isStake ? { from: SPENDING, rule: ANY_TWO_PAIRS } : TRANSFER_TYPES.get(type);
  const expected = { accountId: undefined, accountIdTo: undefined, transactionId: undefined, amount: undefined };

  // The ids and the amount.
  const accountId = decodeDigest(payload.accountId);
  if (accountId === null) say('accountId is not a SHA-256 digest');
  else expected.accountId = accountId;
  const accountIdTo = decodeDigest(payload.accountIdTo);
  if (accountIdTo === null) say('accountIdTo is not a SHA-256 digest');
  else expected.accountIdTo = accountIdTo;
  const previousId = decodeDigest(payload.previousTransactionId);
  if (previousId === null) say('previousTransactionId is not a SHA-256 digest');
  const amount = parseAmount(payload.amount);
  if (amount === null) say(`amount is ${show(payload.amount)}, not a positive whole number of millionths`);
  else expected.amount = amount;
  if (typeof payload.createdAt !== 'string') say('createdAt is not a string');

  // The transaction id: the hash of the transaction without it.
  const transactionId = decodeDigest(payload.transactionId);
  if (transactionId === null) {
    say('transactionId is not a SHA-256 digest');
  } else {
    expected.transactionId = transactionId;
    if (!unsignedHash(payload).equals(transactionId)) say('transactionId is not the hash of the transaction without it');
  }

  // A stake goes to the fund and names its purpose.
  if (isStake) {
    if (accountIdTo !== null && !accountIdTo.equals(FUND_ACCOUNT_ID)) say('a transferToFund goes to the fund, and accountIdTo is another account');
    if (!STAKE_COLUMNS.has(payload.stakeFor)) say(`stakeFor is ${show(payload.stakeFor)}, not one of ${[...STAKE_COLUMNS.keys()].join(', ')}`);
  }

  // The sender: created before this link, of the right type, signing under
  // the type's rule, naming its transaction before this one.
  const senderId = accountId === null ? null : hex(accountId);
  const sender = senderId === null ? undefined : accounts.get(senderId);
  if (senderId !== null && !sender) {
    say(`the sending account ${senderId} was not created by a link before this one`);
  }
  if (sender) {
    checkAccountSignatures(await keysOf(senderId), og.signatures, message, rule, say);
    if (from !== null && sender.type !== from) {
      say(`${type} can only leave a ${from} account, and the sender is a ${sender.type} account`);
    }
    if (previousId !== null && sender.latestTransactionId !== hex(previousId)) {
      say("previousTransactionId is not the sender's transaction before this one");
    }
  }

  // The receiver: created before this link, another account.
  const receiverId = accountIdTo === null ? null : hex(accountIdTo);
  const receiver = receiverId === null ? undefined : accounts.get(receiverId);
  if (receiverId !== null && !receiver) {
    say(`the receiving account ${receiverId} was not created by a link before this one`);
  }
  if (senderId !== null && senderId === receiverId) say('the sender and the receiver are the same account');
  if (type === BREAK_GLASS_TRANSFER && sender && receiver && sender.type !== receiver.type) {
    say(`a break-glass transfer goes to an account of the sender's type, and it goes from a ${sender.type} account to a ${receiver.type} account`);
  }

  // The time lock: a guarded or vault transfer, and a break-glass transfer
  // out of a guarded or vault account, is dated the lock ahead and may be
  // written only once that date has come.
  const locked =
    type === 'guardedAnosTransfer' ||
    type === 'vaultAnosTransfer' ||
    (type === BREAK_GLASS_TRANSFER && sender !== undefined && (sender.type === GUARDED || sender.type === VAULT));
  if (locked && typeof payload.createdAt === 'string') {
    const date = Date.parse(payload.createdAt);
    if (Number.isNaN(date)) {
      say(`createdAt is ${show(payload.createdAt)}, not a date`);
    } else if (row.created_at.getTime() < date) {
      say(`it was written at ${row.created_at.toISOString()}, before its date ${payload.createdAt}`);
    }
  }

  // The stakes.
  if (isStake && senderId !== null && amount !== null && STAKE_COLUMNS.has(payload.stakeFor)) {
    addStake(senderId, payload.stakeFor, amount);
  }
  if (type === BREAK_GLASS_TRANSFER && senderId !== null && receiverId !== null) moveStake(senderId, receiverId);

  return expected;
}

/** A fund proposal: the proposer's signatures, its id, its payouts. Its payout links are due right after it. */
async function checkFundProposal(position, og, payload, message, say) {
  const expected = { accountId: FUND_ACCOUNT_ID, accountIdTo: null, transactionId: undefined, amount: 0n };

  const accountId = decodeDigest(payload.accountId);
  if (accountId === null || !accountId.equals(FUND_ACCOUNT_ID)) say('accountId is not the fund');
  if (typeof payload.createdAt !== 'string') say('createdAt is not a string');

  const transactionId = decodeDigest(payload.transactionId);
  if (transactionId === null) {
    say('transactionId is not a SHA-256 digest');
  } else {
    expected.transactionId = transactionId;
    if (!unsignedHash(payload).equals(transactionId)) say('transactionId is not the hash of the transaction without it');
  }

  // The proposer signs with their own account's keys.
  const guardianId = decodeDigest(payload.guardianId);
  if (guardianId === null) {
    say('guardianId is not a SHA-256 digest');
  } else if (!accounts.has(hex(guardianId))) {
    say(`the proposer, account ${hex(guardianId)}, was not created by a link before this one`);
  } else {
    checkAccountSignatures(await keysOf(hex(guardianId)), og.signatures, message, ANY_TWO_PAIRS, say);
  }

  // The payouts.
  if (!Array.isArray(payload.payouts) || payload.payouts.length === 0) {
    say('payouts is not a list with at least one payout');
    return expected;
  }
  for (const [i, payout] of payload.payouts.entries()) {
    if (!isObject(payout)) {
      say(`payouts[${i}] is not an object`);
      continue;
    }
    const recipient = decodeDigest(payout.accountIdTo);
    if (recipient === null) say(`payouts[${i}].accountIdTo is not a SHA-256 digest`);
    else if (recipient.equals(FUND_ACCOUNT_ID)) say(`payouts[${i}].accountIdTo is the fund`);
    if (parseAmount(payout.amount) === null) {
      say(`payouts[${i}].amount is ${show(payout.amount)}, not a positive whole number of millionths`);
    }
    if (typeof payout.reason !== 'string') say(`payouts[${i}].reason is not a string`);
    if (payout.stakeFor !== undefined && !STAKE_COLUMNS.has(payout.stakeFor)) {
      say(`payouts[${i}].stakeFor is ${show(payout.stakeFor)}, not one of ${[...STAKE_COLUMNS.keys()].join(', ')}`);
    }
  }
  openProposal = { payload, nextIndex: 0, position };
  return expected;
}

/** The object a payout link carries: the proposal's id, the payout's place in the list, the payout's own fields, the type. */
function payoutObject(proposalId, index, { accountIdTo, amount, reason, stakeFor }) {
  const object = { proposalId, index, accountIdTo, amount, reason, transactionType: TRANSFER_FROM_FUND };
  if (stakeFor !== undefined) object.stakeFor = stakeFor;
  return object;
}

/**
 * A payout link (transferFromFund): no signatures of its own. It must be
 * the next payout of the fund proposal right before it, and its id is the
 * hash of the payout object. A payout that returns stake takes it off the
 * receiver's stake.
 */
function checkPayout(payload, canonical, say) {
  const expected = { accountId: FUND_ACCOUNT_ID, accountIdTo: undefined, transactionId: sha256(canonical), amount: undefined };
  if (openProposal === null) {
    say('it is a payout, and the link before it is not a fund proposal with payouts left, nor one of its payouts');
    return expected;
  }
  const { payload: proposal, nextIndex, position } = openProposal;
  const payout = proposal.payouts[nextIndex];
  openProposal = nextIndex + 1 < proposal.payouts.length ? { payload: proposal, nextIndex: nextIndex + 1, position } : null;
  if (!isObject(payout)) return expected;

  if (canonicalize(payoutObject(proposal.transactionId, nextIndex, payout)) !== canonical) {
    say(`it is not payout ${nextIndex} of the fund proposal at link ${position}`);
  }
  const recipient = decodeDigest(payout.accountIdTo);
  if (recipient !== null) {
    expected.accountIdTo = recipient;
    if (!accounts.has(hex(recipient))) say(`the receiving account ${hex(recipient)} was not created by a link before this one`);
  }
  const amount = parseAmount(payout.amount);
  if (amount !== null) expected.amount = amount;
  if (recipient !== null && amount !== null && STAKE_COLUMNS.has(payout.stakeFor)) {
    subtractStake(hex(recipient), payout.stakeFor, amount, say);
  }
  return expected;
}

// ---------------------------------------------------------------------------
// The accounts table and the stakes table against what the links add up to.
// ---------------------------------------------------------------------------

const ACCOUNTS_SQL = `
  SELECT account_id, ${ACCOUNT_KEYS.map(({ column }) => column).join(', ')}, current_balance, type
  FROM accounts
  WHERE $1::bytea IS NULL OR account_id > $1
  ORDER BY account_id
  LIMIT $2`;

async function checkAccountsTable() {
  let total = 0n;
  let after = null;
  for (;;) {
    const { rows } = await db.query(ACCOUNTS_SQL, [after, ACCOUNTS_PER_PAGE]);
    if (rows.length === 0) break;
    for (const row of rows) {
      counts.accountRows += 1;
      counts.accountsByType.set(row.type, (counts.accountsByType.get(row.type) ?? 0) + 1);
      const id = hex(row.account_id);
      const balance = BigInt(row.current_balance);
      total += balance;
      if (row.account_id.equals(FUND_ACCOUNT_ID)) counts.fundBalance = balance;
      const account = accounts.get(id);
      if (!account) {
        problem(`account ${id}: it is in the accounts table with ${anos(balance)}, and no link created it`);
        continue;
      }
      account.inTable = true;
      if (row.type !== account.type) {
        problem(`account ${id}: the accounts table says its type is ${show(row.type)}, and its creation (link ${account.position}) says ${show(account.type)}`);
      }
      if (balance !== account.balance) {
        problem(`account ${id}: the accounts table says ${anos(balance)}, and the links add up to ${anos(account.balance)}`);
      }
      if (!digestOfKeys(ACCOUNT_KEYS.map(({ column }) => row[column])).equals(account.keysDigest)) {
        const keys = await keysOf(id);
        for (const { name, column } of ACCOUNT_KEYS) {
          const inTable = row[column];
          const same = inTable === null || keys[name] === null ? inTable === keys[name] : inTable.equals(keys[name]);
          if (!same) problem(`account ${id}: the ${column} column is not the ${name} of its creation (link ${account.position})`);
        }
      }
    }
    after = rows[rows.length - 1].account_id;
  }
  for (const [id, account] of accounts) {
    if (!account.inTable) problem(`account ${id}: link ${account.position} created it, and it is not in the accounts table`);
  }
  return total;
}

async function checkStakesTable() {
  const columns = [...STAKE_COLUMNS.values()].join(', ');
  const { rows } = await db.query(`SELECT account_id, ${columns} FROM stakes ORDER BY account_id`);
  const seen = new Set();
  for (const row of rows) {
    counts.stakeRows += 1;
    const id = hex(row.account_id);
    seen.add(id);
    const stake = stakes.get(id) ?? emptyStake();
    for (const [purpose, column] of STAKE_COLUMNS) {
      const inTable = BigInt(row[column]);
      counts.stakedFor.set(purpose, (counts.stakedFor.get(purpose) ?? 0n) + inTable);
      if (inTable !== stake[purpose]) {
        problem(`stake of account ${id}: the stakes table says ${anos(inTable)} for ${purpose}, and the links add up to ${anos(stake[purpose])}`);
      }
    }
  }
  for (const [id, stake] of stakes) {
    if (seen.has(id)) continue;
    for (const purpose of STAKE_COLUMNS.keys()) {
      if (stake[purpose] !== 0n) {
        problem(`stake of account ${id}: the links add up to ${anos(stake[purpose])} for ${purpose}, and the account has no row in the stakes table`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// The run.
// ---------------------------------------------------------------------------

/**
 * The database settings: the environment first, then the validator's .env,
 * then its network/testnet.env, the order the server itself reads them in.
 */
function readSettings(repo) {
  const fromFiles = {};
  const unread = [];
  for (const name of ['network/testnet.env', '.env']) {
    try {
      Object.assign(fromFiles, parseEnv(readFileSync(join(repo, name), 'utf8')));
    } catch (err) {
      unread.push(`${join(repo, name)} (${err.code ?? err.message})`);
    }
  }
  const setting = (name) => process.env[name] || fromFiles[name];
  const hint = unread.length === 0
    ? ''
    : ` Could not read ${unread.join(' or ')}: run it as the anos user (sudo -iu anos node <this file>), or name the validator's folder with --repo <folder>.`;
  const connection = {
    host: setting('PGHOST') || '127.0.0.1',
    port: Number(setting('PGPORT')) || 5432,
    user: setting('PGUSER'),
    password: setting('PGPASSWORD'),
    database: setting('PGDATABASE'),
  };
  if (!connection.user || !connection.database) throw new Error(`the database settings are missing.${hint}`);
  return { connection, validatorId: fromFiles.VALIDATOR_ID, hint };
}

async function main() {
  const { values } = parseArgs({ options: { repo: { type: 'string' }, help: { type: 'boolean' } } });
  if (values.help) {
    console.log('usage: sudo -iu anos node verify-garlic-chain.mjs [--repo <the validator\'s folder>]');
    console.log(`The folder is ${DEFAULT_REPO} when --repo is left out.`);
    return 0;
  }
  const repo = resolve(values.repo ?? DEFAULT_REPO);

  try {
    selfTest();
  } catch (err) {
    throw new Error(`this Node (${process.version}) cannot check signatures the way the validator does: ${err.message}`);
  }

  // pg and canonicalize, from the validator's own node_modules.
  let pg;
  try {
    const require = createRequire(join(repo, 'package.json'));
    pg = require('pg');
    canonicalize = (await import(pathToFileURL(require.resolve('canonicalize')).href)).default;
  } catch (err) {
    throw new Error(`could not load pg and canonicalize from ${join(repo, 'node_modules')}: ${err.message.split('\n')[0]}`);
  }

  const { connection, validatorId, hint } = readSettings(repo);
  db = new pg.Client({ ...connection, application_name: 'verify-garlic-chain' });
  try {
    await db.connect();
  } catch (err) {
    throw new Error(`could not connect to database ${connection.database} on ${connection.host}: ${err.message}.${hint}`);
  }
  try {
    // One read-only snapshot for everything that is read.
    await db.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const { rows: [moment] } = await db.query('SELECT now() AS now, current_database() AS database');

    console.log('Garlic chain check');
    console.log(`  ${validatorId ? `validator ${validatorId}, ` : ''}database ${moment.database} on ${connection.host}`);
    console.log(`  read as it stood at ${moment.now.toISOString()}`);
    console.log('');

    // The links.
    let after = null;
    let lastNote = Date.now();
    for (;;) {
      const { rows } = await db.query(LINKS_SQL, [after, LINKS_PER_PAGE]);
      if (rows.length === 0) break;
      for (const row of rows) await checkLink(row);
      after = rows[rows.length - 1].position;
      if (Date.now() - lastNote > 5000) {
        console.error(`  ... ${count(counts.links)} links checked so far`);
        lastNote = Date.now();
      }
    }
    if (openProposal !== null) reportMissingPayouts();
    if (counts.links === 0) problem('the garlic chain has no links');
    else if (!fundCreatedByGenesis) problem('neither of the first two links creates the fund account');

    // The two tables.
    const total = await checkAccountsTable();
    await checkStakesTable();
    const genesisTotal = FUND_GENESIS_BALANCE + FIRST_ACCOUNT_GENESIS_BALANCE;
    if (total !== genesisTotal) {
      problem(`all the balances in the accounts table add up to ${anos(total)}, and the genesis made ${anos(genesisTotal)}`);
    }

    report(total);
  } finally {
    await db.query('ROLLBACK').catch(() => {});
    await db.end();
  }
  return problemCount === 0 ? 0 : 1;
}

function report(total) {
  const line = (label, value) => console.log(`  ${label.padEnd(26)}${value}`);

  console.log('Garlic chain');
  if (counts.links === 0) {
    line('links', '0');
  } else {
    line('links', `${count(counts.links)}, positions ${counts.firstPosition} to ${previousLink.position}`);
    for (const [type, number] of [...counts.byType].sort((a, b) => b[1] - a[1])) line(`  ${type}`, count(number));
    line('signatures checked', count(counts.signatures));
    line('last link', `position ${previousLink.position}`);
    line('its record hash', hex(previousLink.recordHash));
  }
  console.log('');
  console.log('Accounts');
  line('rows', count(counts.accountRows));
  for (const [type, number] of [...counts.accountsByType].sort((a, b) => b[1] - a[1])) line(`  ${type}`, count(number));
  if (counts.fundBalance !== null) line('the fund holds', anos(counts.fundBalance));
  line('all balances together', anos(total));
  console.log('');
  console.log('Stakes');
  line('rows', count(counts.stakeRows));
  for (const [purpose, staked] of counts.stakedFor) {
    if (staked !== 0n) line(`  ${purpose}`, anos(staked));
  }
  console.log('');

  if (problemCount === 0) {
    console.log('Every link, every signature, every account row and every stake row was checked.');
    console.log('The last link above is this validator\'s chain tail: another validator whose /health');
    console.log('shows the same position and record hash holds the same chain.');
    console.log('');
    console.log('EVERYTHING IS PERFECT. No problem found.');
    return;
  }
  console.log(`PROBLEMS FOUND: ${count(problemCount)}`);
  console.log('');
  problems.forEach((text, i) => console.log(`  ${i + 1}. ${text}`));
  if (problemCount > problems.length) {
    console.log(`  ... and ${count(problemCount - problems.length)} more, not printed.`);
  }
}

try {
  process.exitCode = await main();
} catch (err) {
  console.error(`The check could not run: ${err.message}`);
  process.exitCode = 2;
}
