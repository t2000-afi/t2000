/// Agent ID — on-chain registry of agent identities (SPEC_AGENT_ID Phase B).
///
/// One shared `Registry` holds a `Table<address, AgentRecord>`. An agent
/// registers ITSELF (`sender == agent` — self-sovereign); ownership by a human
/// Passport is two-sided (the agent proposes a `pending_owner`, the owner
/// confirms) to prevent false owner claims. Identity is anchored to the
/// agent's Sui address; the SuiNS handle (`<label>.agent-id.sui`) lives OFF
/// this object (SuiNS is the handle truth) — only address-anchored identity,
/// ownership, endpoints, and pointers are on-chain (minimal + public).
///
/// Upgrade-safety: the package is upgradeable; `Registry.version` is gated
/// against the package `VERSION` so a stale package version can't mutate state
/// after an upgrade until `migrate` (AdminCap-gated) bumps it.
module agent_id::registry;

use std::string::String;
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

/// Bump on every breaking package upgrade; `migrate` advances a deployed
/// `Registry` to match (the canonical Sui upgradeable-shared-object pattern).
/// v2 (S.1032): ownership mutators deprecated; set_active agent-only.
const VERSION: u64 = 2;

// === Errors ===
const EAlreadyRegistered: u64 = 0;
const ENotRegistered: u64 = 1;
const ENotAuthorized: u64 = 2;
#[allow(unused_const)]
const ENoPendingOwner: u64 = 3;
const EWrongVersion: u64 = 4;
/// Passport↔agent ownership left the product (S.1032, founder lock
/// 2026-08-13). The mutators below keep their signatures (compatible
/// upgrade) but always abort with THIS code — a dedicated abort so ops can
/// tell "deprecated surface" from a real auth failure. Historical
/// `owner` / `pending_owner` fields stay on records (layout is frozen);
/// they are inert chain cosmetics.
const EOwnershipDeprecated: u64 = 5;

// === Objects ===

/// Governance authority (held by the COLD deployer): gates `migrate` after an
/// upgrade. Separate from the leaf-mint custody (hot) so the upgrade authority
/// never lives on the server.
public struct AdminCap has key, store {
    id: UID,
}

/// The shared registry: `agent address → AgentRecord`, plus the ERC-8004-style
/// numeric-id counter + the version gate. Shared so it's globally queryable and
/// so Phase-C reputation can attach (via a separate object / dynamic field —
/// `AgentRecord` fields are fixed post-deploy). Sui `Table` uses dynamic
/// fields, so updates to different agents don't contend.
public struct Registry has key {
    id: UID,
    version: u64,
    agents: Table<address, AgentRecord>,
    next_id: u64,
}

/// One agent's on-chain identity. Minimal + public by design; rich metadata
/// lives off-chain via `metadata_uri` (Walrus). NOTE: Move cannot add fields to
/// this struct in an upgrade — future data (reputation) attaches as a separate
/// object/dynamic field, not a new field here.
public struct AgentRecord has store {
    agent: address,
    numeric_id: u64,
    owner: Option<address>,
    pending_owner: Option<address>,
    mcp_endpoint: Option<String>,
    payment_methods: vector<String>,
    did: Option<String>,
    metadata_uri: Option<String>,
    active: bool,
    created_at_ms: u64,
    updated_at_ms: u64,
}

// === Events (consumed by the off-chain indexer → the DB read-cache) ===
public struct AgentRegistered has copy, drop {
    agent: address,
    numeric_id: u64,
    timestamp_ms: u64,
}
public struct AgentUpdated has copy, drop { agent: address, timestamp_ms: u64 }
#[allow(unused_field)]
public struct PendingOwnerSet has copy, drop {
    agent: address,
    pending_owner: address,
    timestamp_ms: u64,
}
#[allow(unused_field)]
public struct OwnerLinked has copy, drop {
    agent: address,
    owner: address,
    timestamp_ms: u64,
}
public struct AgentActiveSet has copy, drop {
    agent: address,
    active: bool,
    timestamp_ms: u64,
}
public struct OwnershipRenounced has copy, drop {
    agent: address,
    owner: address,
    timestamp_ms: u64,
}

// === Init (runs once on publish) ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        version: VERSION,
        agents: table::new(ctx),
        next_id: 1,
    });
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Reject calls against a `Registry` whose version doesn't match the running
/// package — forces `migrate` after an upgrade before mutations resume.
fun assert_version(registry: &Registry) {
    assert!(registry.version == VERSION, EWrongVersion);
}

// === Register (self-sovereign: sender == the agent) ===
public fun register(
    registry: &mut Registry,
    mcp_endpoint: Option<String>,
    payment_methods: vector<String>,
    did: Option<String>,
    metadata_uri: Option<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(registry);
    let agent = ctx.sender();
    assert!(!registry.agents.contains(agent), EAlreadyRegistered);
    let now = clock.timestamp_ms();
    let numeric_id = registry.next_id;
    registry.next_id = numeric_id + 1;
    registry.agents.add(agent, AgentRecord {
        agent,
        numeric_id,
        owner: option::none(),
        pending_owner: option::none(),
        mcp_endpoint,
        payment_methods,
        did,
        metadata_uri,
        active: true,
        created_at_ms: now,
        updated_at_ms: now,
    });
    event::emit(AgentRegistered { agent, numeric_id, timestamp_ms: now });
}

// === Update (agent-only — sender is the record key). Full-replace: the caller
//     supplies the complete desired state (omitting a field clears it). ===
public fun update(
    registry: &mut Registry,
    mcp_endpoint: Option<String>,
    payment_methods: vector<String>,
    did: Option<String>,
    metadata_uri: Option<String>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(registry);
    let agent = ctx.sender();
    assert!(registry.agents.contains(agent), ENotRegistered);
    let now = clock.timestamp_ms();
    let record = registry.agents.borrow_mut(agent);
    record.mcp_endpoint = mcp_endpoint;
    record.payment_methods = payment_methods;
    record.did = did;
    record.metadata_uri = metadata_uri;
    record.updated_at_ms = now;
    event::emit(AgentUpdated { agent, timestamp_ms: now });
}

// === Ownership link — DEPRECATED (S.1032, v2) ===
// Signatures survive (Sui compatible upgrades cannot remove or rename public
// functions); bodies always abort. Event structs stay declared for type
// compatibility — they simply never emit again. NOTE: the abort is only half
// the cutover — until `migrate` bumps the shared Registry to v2, the OLD
// package id still runs the v1 bodies. Same ritual as escrow S.981/S.1019.

/// DEPRECATED — always aborts with `EOwnershipDeprecated`.
public fun set_pending_owner(
    registry: &mut Registry,
    _owner: address,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(registry);
    abort EOwnershipDeprecated
}

/// DEPRECATED — always aborts with `EOwnershipDeprecated`.
public fun confirm_ownership(
    registry: &mut Registry,
    _agent: address,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(registry);
    abort EOwnershipDeprecated
}

/// DEPRECATED — always aborts with `EOwnershipDeprecated`. Historical links
/// (e.g. #74's) stay as inert record fields — founder lock: no forced
/// renounce, the product simply ignores them.
public fun renounce_ownership(
    registry: &mut Registry,
    _agent: address,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert_version(registry);
    abort EOwnershipDeprecated
}

// === Active toggle (AGENT-ONLY since v2 — S.1032) ===
/// Reversible — deactivate OR reactivate. (Replaces a one-way deactivate so an
/// agent can't get stuck inactive: the record persists, blocking re-register.)
/// v2 dropped the owner arm: a leftover linked owner must not be able to
/// deactivate/reactivate an agent after ownership left the product.
public fun set_active(
    registry: &mut Registry,
    agent: address,
    active: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(registry);
    assert!(registry.agents.contains(agent), ENotRegistered);
    let sender = ctx.sender();
    let now = clock.timestamp_ms();
    let record = registry.agents.borrow_mut(agent);
    assert!(sender == agent, ENotAuthorized);
    record.active = active;
    record.updated_at_ms = now;
    event::emit(AgentActiveSet { agent, active, timestamp_ms: now });
}

// === Admin: migrate the shared Registry after a package upgrade ===
public fun migrate(registry: &mut Registry, _: &AdminCap) {
    assert!(registry.version < VERSION, EWrongVersion);
    registry.version = VERSION;
}

// === Read accessors (for composing contracts: Phase-C reputation, Commerce) ===
public fun is_registered(registry: &Registry, agent: address): bool {
    registry.agents.contains(agent)
}

public fun borrow_record(registry: &Registry, agent: address): &AgentRecord {
    registry.agents.borrow(agent)
}

public fun numeric_id(record: &AgentRecord): u64 { record.numeric_id }
public fun owner(record: &AgentRecord): Option<address> { record.owner }
public fun is_active(record: &AgentRecord): bool { record.active }
public fun mcp_endpoint(record: &AgentRecord): Option<String> { record.mcp_endpoint }
public fun did(record: &AgentRecord): Option<String> { record.did }

// === Test-only hooks ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_version_for_testing(registry: &mut Registry, version: u64) {
    registry.version = version;
}

#[test_only]
public fun current_version(): u64 { VERSION }

#[test_only]
public fun version(registry: &Registry): u64 { registry.version }
