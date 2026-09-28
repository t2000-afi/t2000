/**
 * Wallet-side coin selection helpers — single source of truth for the
 * "produce a `Coin<T>` argument holding `amount` raw units of `coinType`,
 * owned by `address`" pattern. Used by every wallet-mode appender that
 * needs a coin input (save, send, swap, repay, stake, etc.).
 *
 * **2026-05-22 — address-balance migration.** Sui mainnet's address-balance
 * feature ships funds account-style instead of as discrete `Coin<T>` objects.
 * After a payment via `0x2::balance::send_funds`, the leftover lands in the
 * sender's address balance with a synthetic "coin reservation" representing
 * the deposit. `client.getCoins()` correctly filters those reservations out
 * (they aren't real owned objects), so the old fetch+merge+split pattern
 * threw `INSUFFICIENT_BALANCE` for users whose stables had drifted into
 * address balance — even when `getBalance().totalBalance` showed plenty.
 *
 * The fix is structural: hand the work to `coinWithBalance({ type, balance })`
 * from `@mysten/sui/transactions`. Its build-time resolver inspects coins +
 * address balance together (`getBalance` + `listCoins`), then emits the
 * right shape — direct `redeem_funds` from address balance when AB ≥
 * required, or merge-and-split across coins + AB withdrawal when not. Multi
 * intents per coin type get batched into a single merge in one PTB, so the
 * old per-PTB merge cache is no longer needed.
 *
 * Pre-flight uses `client.getBalance().totalBalance` (sums coins + AB)
 * instead of summing the paginated `getCoins` page. That's the OTHER half
 * of the migration — the legacy path could see `0` from `getCoins` and
 * mistakenly throw before `coinWithBalance` ever ran.
 */
import {
  Transaction,
  coinWithBalance,
  type TransactionObjectArgument,
} from '@mysten/sui/transactions';
import type { SuiCoreClient } from '../utils/sui.js';
import { T2000Error } from '../errors.js';
import { getDecimalsForCoinType, resolveSymbol } from '../token-registry.js';

/** Raw units → exact display string for error copy (S.1194): decimal point
 *  inserted via string math (no float loss), truncated to the display
 *  precision — truncation IS the floor rule for positive amounts (the
 *  t2000-financial-amounts law: shown ≤ actual, never rounded up). */
function formatRawAmount(raw: bigint, coinType: string): string {
  const decimals = getDecimalsForCoinType(coinType);
  const dp = Math.min(decimals, 8);
  const s = raw.toString().padStart(decimals + 1, '0');
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).slice(0, dp).replace(/0+$/, '');
  return frac ? `${whole}.${frac}` : whole;
}

export interface CoinPage {
  ids: string[];
  totalBalance: bigint;
}

/**
 * Sum every coin of `coinType` owned by `owner`, INCLUDING address balance.
 * Returns the IDs of any discrete coin objects that exist (callers
 * occasionally need this for non-`coinWithBalance` paths, e.g. SUIns name
 * registration which expects raw object IDs).
 *
 * Pre-2026-05-22 this function paginated `client.getCoins` and summed
 * the page balances. That misses address-balance funds (the SDK filters
 * them out of `getCoins` for back-compat). The new implementation calls
 * `getBalance` for the canonical total and `getCoins` for the optional
 * ID list — both round-trips, but they happen in parallel.
 */
export async function fetchAllCoins(
  client: SuiCoreClient,
  owner: string,
  coinType: string,
): Promise<CoinPage> {
  const [balance, ids] = await Promise.all([
    client.core.getBalance({ owner, coinType }),
    (async () => {
      const out: string[] = [];
      let cursor: string | null | undefined;
      let hasNext = true;
      while (hasNext) {
        const page = await client.core.listCoins({ owner, coinType, cursor: cursor ?? undefined });
        for (const c of page.objects) out.push(c.objectId);
        cursor = page.cursor;
        hasNext = page.hasNextPage;
      }
      return out;
    })(),
  ]);
  return { ids, totalBalance: BigInt(balance.balance.balance) };
}

export interface SelectAndSplitResult {
  /** TransactionObjectArgument for a coin holding `effectiveAmount` raw units. */
  coin: TransactionObjectArgument;
  /** Actual raw amount the returned coin holds. May be < requested if `swapAll` is true. */
  effectiveAmount: bigint;
  /** True iff the request consumed the entire wallet balance (no split needed). */
  swapAll: boolean;
}

/**
 * Wallet-mode coin selection prelude. Pre-flights against
 * `getBalance().totalBalance` (coins + address balance combined), then
 * returns a `coinWithBalance({ type, balance })` argument that the
 * `@mysten/sui` resolver fulfills at build time.
 *
 * Throws `T2000Error` (`INSUFFICIENT_BALANCE`) when:
 * - `amount` is bigger than the total balance AND the caller did NOT
 *   opt into `swapAll: true` clipping.
 * - `amount === 'all'` AND total balance is zero.
 *
 * @param tx — PTB to register the `coinWithBalance` intent against.
 * @param client — Sui RPC client for the pre-flight `getBalance` lookup.
 * @param owner — wallet address whose coins to source from.
 * @param coinType — fully-qualified Sui coin type (e.g. `"0x...::usdc::USDC"`).
 * @param amount — raw amount to source (in MIST / smallest unit). Pass
 *   `'all'` to consume the entire balance.
 * @param options.allowSwapAll — if true (default), `amount` >= totalBalance
 *   auto-clips to total. If false, throws when the request would over-consume.
 * @param options.sponsoredContext — when true, source ONLY from discrete coin
 *   objects (never the address balance). See the long note below — this exists
 *   because Enoki's gas station can't yet deserialize a `TransactionData` that
 *   contains the address-balance `FundsWithdrawal` reservation that
 *   `coinWithBalance` emits. Self-funded callers leave this false: the fullnode
 *   handles `FundsWithdrawal` fine, so the address-balance path is preferred
 *   (it can reach funds that aren't held as coin objects).
 *
 * @returns
 *   - `coin` — `TransactionObjectArgument` ready for downstream consumption.
 *   - `effectiveAmount` — the raw amount the returned coin holds (handles
 *     swapAll clipping).
 *   - `swapAll` — true iff the entire balance was consumed.
 */
export async function selectAndSplitCoin(
  tx: Transaction,
  client: SuiCoreClient,
  owner: string,
  coinType: string,
  amount: bigint | 'all',
  options: {
    allowSwapAll?: boolean;
    sponsoredContext?: boolean;
    mergeCache?: SponsoredCoinMergeCache;
  } = {},
): Promise<SelectAndSplitResult> {
  // [2026-05-30] Sponsored Enoki path — coin objects only. `coinWithBalance`
  // reaches into the address balance (mysten Address Balances feature) when
  // `addressBalance >= required`, emitting `0x2::coin::redeem_funds` + a
  // `FundsWithdrawal` reservation input. That input is a newer `TransactionData`
  // field; Enoki's sponsor endpoint accepts the kind bytes (200) but its gas
  // station rejects the assembled `TransactionData` at execute with
  // "Invalid bcs bytes for TransactionData". The fullnode parses it fine — only
  // Enoki can't (yet). So under sponsorship we source from discrete coin objects
  // and surface a clear error when the user's funds are address-balance-only.
  // See github.com/t2000-afi/t2000 issue #93.
  if (options.sponsoredContext) {
    return selectCoinObjectsOnly(
      tx,
      client,
      owner,
      coinType,
      amount,
      options.allowSwapAll ?? true,
      options.mergeCache,
    );
  }

  const balanceResp = await client.core.getBalance({ owner, coinType });
  const totalBalance = BigInt(balanceResp.balance.balance);

  // S.1194: money errors speak SYMBOL + human amounts, never the raw
  // coin type — `0xdba3…::usdc::USDC` is machine data and was reaching
  // console/CLI error lines verbatim. Raw units stay in `details`.
  const symbol = resolveSymbol(coinType);
  if (totalBalance === 0n) {
    throw new T2000Error(
      'INSUFFICIENT_BALANCE',
      amount === 'all'
        ? `No ${symbol} in this wallet.`
        : `Insufficient ${symbol}: need ${formatRawAmount(amount, coinType)}, the wallet holds 0.`,
      { available: '0', required: amount === 'all' ? '0' : amount.toString(), coinType },
    );
  }

  const allowSwapAll = options.allowSwapAll ?? true;

  if (amount !== 'all' && amount > totalBalance && !allowSwapAll) {
    throw new T2000Error(
      'INSUFFICIENT_BALANCE',
      `Insufficient ${symbol}: need ${formatRawAmount(amount, coinType)}, the wallet holds ${formatRawAmount(totalBalance, coinType)}.`,
      {
        available: totalBalance.toString(),
        required: amount.toString(),
        coinType,
      },
    );
  }

  const requested = amount === 'all' ? totalBalance : amount;
  const swapAll = amount === 'all' || requested >= totalBalance;
  const effectiveAmount = swapAll ? totalBalance : requested;

  const coin = coinWithBalance({ type: coinType, balance: effectiveAmount })(tx);

  return { coin, effectiveAmount, swapAll };
}

/**
 * Coin-object-only selection for sponsored (Enoki) transactions. Fetches the
 * owner's discrete `Coin<T>` objects (NOT the address balance — `getCoins`
 * excludes it), merges them, and splits the requested amount. Never emits a
 * `FundsWithdrawal` reservation, so the resulting `TransactionData` stays on
 * the shape Enoki's gas station can serialize.
 *
 * Throws `ADDRESS_BALANCE_UNSPONSORABLE` when the coin objects don't cover the
 * request — which, for a user whose `getBalance().totalBalance` shows funds,
 * means those funds live in the address balance (e.g. received via a gasless
 * stablecoin transfer) and can't be moved through a sponsored transaction yet.
 */
/**
 * Per-PTB cache of merged sponsored coin-object primaries, keyed by coin
 * type. The FIRST `selectCoinObjectsOnly` call for a given coin type in a
 * PTB fetches the owner's discrete `Coin<T>` objects, merges them into one
 * `primary`, and records it here alongside the remaining (unspent) balance.
 * EVERY subsequent leg sourcing the same coin type splits from that cached
 * `primary` instead of re-fetching + re-merging.
 *
 * Why this exists (S.xxx, 2026-06-02): a sponsored bundle with 2+ legs
 * sourcing the same coin (e.g. `SUI→WAL` + `SUI→DEEP`, or `swap USDC` +
 * `save USDC`) called `selectCoinObjectsOnly` once per leg. Each call
 * emitted its own `mergeCoins` over the SAME coin objects, so the second
 * leg's merge referenced coins the first leg already consumed → Enoki
 * dry-run failed with `CommandArgumentError { ArgumentWithoutValue }`.
 *
 * This is NOT SUI-specific. Under sponsorship, `selectAndSplitCoin` routes
 * EVERY asset through `selectCoinObjectsOnly` (the `coinWithBalance`
 * batching that would otherwise dedup these merges only runs for
 * non-sponsored CLI/direct flows — its address-balance `FundsWithdrawal`
 * reservation is what Enoki can't deserialize, issue #93). So the cache is
 * the dedup layer for ALL coin types in a sponsored multi-leg PTB, keyed
 * by coin type. SUI was simply the first asset observed failing in the
 * wild because it's the most common swap source.
 */
export type SponsoredCoinMergeCache = Map<
  string,
  { primary: TransactionObjectArgument; remaining: bigint }
>;

async function selectCoinObjectsOnly(
  tx: Transaction,
  client: SuiCoreClient,
  owner: string,
  coinType: string,
  amount: bigint | 'all',
  allowSwapAll: boolean,
  mergeCache?: SponsoredCoinMergeCache,
): Promise<SelectAndSplitResult> {
  // Cache hit — a prior leg in THIS PTB already merged this coin type's
  // objects into `cached.primary`. Re-running the fetch+merge below would
  // emit a second `mergeCoins` over already-consumed coins → dry-run
  // `ArgumentWithoutValue`. Split from the cached primary instead.
  const cached = mergeCache?.get(coinType);
  if (cached) {
    const requested = amount === 'all' ? cached.remaining : amount;
    if (cached.remaining === 0n || requested > cached.remaining) {
      throw new T2000Error(
        'ADDRESS_BALANCE_UNSPONSORABLE',
        `Not enough ${resolveSymbol(coinType)} in coin objects to cover all legs of this ` +
          `sponsored bundle. The remaining funds are in your address balance, ` +
          `which sponsored transactions can't access yet.`,
        { remaining: cached.remaining.toString(), requested: requested.toString(), coinType },
      );
    }
    const swapAll = amount === 'all' || requested >= cached.remaining;
    const effectiveAmount = swapAll ? cached.remaining : requested;
    const coin = swapAll
      ? cached.primary
      : tx.splitCoins(cached.primary, [effectiveAmount])[0];
    cached.remaining -= effectiveAmount;
    return { coin, effectiveAmount, swapAll };
  }

  const objects: { objectId: string; balance: bigint }[] = [];
  let coinObjectTotal = 0n;
  let cursor: string | null | undefined;
  let hasNext = true;
  while (hasNext) {
    const page = await client.core.listCoins({ owner, coinType, cursor: cursor ?? undefined });
    for (const c of page.objects) {
      objects.push({ objectId: c.objectId, balance: BigInt(c.balance) });
      coinObjectTotal += BigInt(c.balance);
    }
    cursor = page.cursor;
    hasNext = page.hasNextPage;
  }

  const unsponsorable = (): T2000Error =>
    new T2000Error(
      'ADDRESS_BALANCE_UNSPONSORABLE',
      `These funds are in your address balance, which sponsored transactions ` +
        `can't access yet. (Funds received via gasless transfers land there.) ` +
        `This will work once the gas sponsor adds address-balance support.`,
      { coinObjectTotal: coinObjectTotal.toString(), coinType },
    );

  if (coinObjectTotal === 0n) {
    throw unsponsorable();
  }

  const requested = amount === 'all' ? coinObjectTotal : amount;
  if (requested > coinObjectTotal) {
    // Not enough in coin objects. If the caller allows clipping to the
    // available coin-object total ("swap all"), do so; otherwise the shortfall
    // is sitting in the address balance → unsponsorable.
    if (allowSwapAll && amount === 'all') {
      // unreachable (requested === coinObjectTotal here) — kept for clarity.
    } else {
      throw unsponsorable();
    }
  }

  const swapAll = amount === 'all' || requested >= coinObjectTotal;
  const effectiveAmount = swapAll ? coinObjectTotal : requested;

  const [first, ...rest] = objects;
  const primary = tx.object(first.objectId);
  if (rest.length > 0) {
    tx.mergeCoins(
      primary,
      rest.map((o) => tx.object(o.objectId)),
    );
  }

  // Consume the whole merged coin when taking everything; otherwise split the
  // exact amount and leave the remainder on the (sender-owned) primary coin.
  const coin = swapAll ? primary : tx.splitCoins(primary, [effectiveAmount])[0];

  // Record the merged primary so later legs in the same PTB reuse it
  // rather than re-fetching + re-merging the same (now-consumed) coins.
  // When `swapAll`, the primary was consumed (remaining 0) — a later leg
  // hitting the cache then throws the unsponsorable shortfall above.
  mergeCache?.set(coinType, {
    primary,
    remaining: coinObjectTotal - effectiveAmount,
  });

  return { coin, effectiveAmount, swapAll };
}

/**
 * Build a GASLESS coin→address-balance migration.
 *
 * Sends WHOLE `Coin<T>` objects to `owner`'s OWN SIP-58 address balance via
 * `0x2::coin::send_funds(coin, owner)` — one allowlisted framework MoveCall
 * per coin, with NO native `SplitCoins` / `MergeCoins` commands. That shape is
 * what makes it gasless: the gRPC build resolver only zeros gas for PTBs whose
 * every command is a MoveCall into the `0x2` gasless allowlist (`send_funds` /
 * `redeem_funds` / `withdrawal_split` / `into_balance`). The same eligibility
 * the gasless `balance::send_funds` send + the x402 `redeem_funds`+`send_funds`
 * withdrawal rely on. (The old migration merged+split first → native commands →
 * fell outside the allowlist → needed SUI. See `pay.ts ensureAddressBalanceCovers`.)
 *
 * Selects the FEWEST coins (largest first) whose combined balance covers
 * `minAmount`, minimizing the MoveCall count. Over-migration is harmless — the
 * surplus just lands in the address balance. Pure / network-free: callers pass
 * coins they've already fetched, so this is unit-testable offline.
 *
 * Throws `INSUFFICIENT_BALANCE` when the supplied coin objects can't cover
 * `minAmount`.
 */
export function buildCoinToAddressBalanceMigration(args: {
  coins: { objectId: string; balance: bigint }[];
  coinType: string;
  owner: string;
  minAmount: bigint;
}): { tx: Transaction; migratedRaw: bigint } {
  const { coins, coinType, owner, minAmount } = args;

  // Largest first → fewest whole-coin sends to cover the shortfall.
  const sorted = [...coins]
    .filter((c) => c.balance > 0n)
    .sort((a, b) => (b.balance > a.balance ? 1 : b.balance < a.balance ? -1 : 0));

  const selected: { objectId: string; balance: bigint }[] = [];
  let migratedRaw = 0n;
  for (const c of sorted) {
    if (migratedRaw >= minAmount) break;
    selected.push(c);
    migratedRaw += c.balance;
  }

  if (migratedRaw < minAmount) {
    throw new T2000Error('INSUFFICIENT_BALANCE', `Insufficient ${resolveSymbol(coinType)} coin objects to migrate`, {
      available: migratedRaw.toString(),
      required: minAmount.toString(),
    });
  }

  const tx = new Transaction();
  for (const c of selected) {
    tx.moveCall({
      target: '0x2::coin::send_funds',
      typeArguments: [coinType],
      arguments: [tx.object(c.objectId), tx.pure.address(owner)],
    });
  }
  return { tx, migratedRaw };
}

/**
 * SUI-specific coin selection. Branches on sponsorship context:
 *
 * - **Self-funded (`sponsoredContext: false`)** — splits from `tx.gas`
 *   directly (the user's gas coin IS their SUI). More efficient — no
 *   `getBalance` RTT.
 *
 * - **Sponsored (`sponsoredContext: true`)** — sources from the user's
 *   discrete SUI coin objects (`selectCoinObjectsOnly`). This both (a) avoids
 *   `tx.gas`, which belongs to the Enoki sponsor — NOT the user — under
 *   sponsored flows (the original S.260 reason for `useGasCoin: false`), AND
 *   (b) avoids `coinWithBalance`'s address-balance `FundsWithdrawal`, which
 *   Enoki's gas station can't deserialize (issue #93). If the user's SUI is
 *   address-balance-only, it raises `ADDRESS_BALANCE_UNSPONSORABLE`.
 */
export async function selectSuiCoin(
  tx: Transaction,
  client: SuiCoreClient,
  owner: string,
  amountMist: bigint,
  sponsoredContext: boolean,
  mergeCache?: SponsoredCoinMergeCache,
): Promise<SelectAndSplitResult> {
  if (sponsoredContext) {
    const { SUI_TYPE } = await import('../token-registry.js');
    return selectCoinObjectsOnly(tx, client, owner, SUI_TYPE, amountMist, false, mergeCache);
  }

  const [coin] = tx.splitCoins(tx.gas, [amountMist]);
  return { coin, effectiveAmount: amountMist, swapAll: false };
}
