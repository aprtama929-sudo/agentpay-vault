# AgentPay Vault — Scoped Payment Mandates for AI Agents

**Built for the Aevum Builder Challenge #1 (QDay) — stablecoin payments on the Aevum testnet with tUSD8.**

AI agents are starting to buy things: API calls, data, compute, merchant checkouts.
Handing an agent a raw wallet key is reckless — one bug or one prompt injection and
the wallet is empty. Handing it nothing makes it useless.

**AgentPay Vault is the middle ground: an on-chain payment mandate.** A principal
(a human, a merchant backend, or another program) authorizes one agent address to
spend tUSD8 under hard limits enforced by the contract itself:

| Control | Meaning |
|---|---|
| **Per-transaction cap** | No single payment can exceed this amount |
| **Total budget** | Lifetime spend across the whole mandate |
| **Expiry** | The mandate dies at a fixed time — a session window |
| **Payee allowlist** | Optional: the agent can only pay approved addresses |
| **Instant revocation** | Owner kills the mandate in one tx; unspent funds return immediately |
| **Audit trail** | Every create / fund / allowlist / pay / revoke is an on-chain event with a free-text memo (invoice id, order hash, …) |

The agent pays freely *inside* the mandate — no human in the loop, no per-payment
approval — and **provably cannot exceed it**. This mirrors the scoped session-key /
policy-engine model of ERC-4337 agent wallets, implemented as a small, auditable,
dependency-free Solidity contract that any builder can drop into an agent stack today.

## Architecture

```
 Principal (owner EOA / backend)                Agent (EOA or smart account)
        │                                                  │
        │ createMandate(agent, tUSD8, cap, budget,         │
        │               expiry, allowlist?)                │
        │ fund(id, amount)  ── tUSD8 ──►  ┌───────────────────────────┐
        │ setPayeeAllowed(id, merchant)   │      AgentPayVault        │
        │                                 │  mandate #id              │
        │                                 │   funded  1,000 tUSD8     │
        │                                 │   spent       0           │   pay(id, merchant,
        │                                 │   cap/tx    250           │ ◄─ 200, "invoice-001")
        │                                 │   budget  1,000           │
        │                                 │   expires in 7 days       │
        │                                 └─────────────┬─────────────┘
        │                                               │ transfer 200 tUSD8
        │                                               ▼
        │                                           Merchant
        │ revoke(id) ── unspent 800 tUSD8 return to owner, mandate dead
```

One contract, `src/AgentPayVault.sol` (~330 lines, no external dependencies):
- `createMandate` / `fund` / `setPayeeAllowed` — owner-side setup
- `pay` — agent-side execution; enforces revoked → expired → per-tx cap → total
  budget → deposited funds → allowlist, in that order, with typed errors
- `revoke` / `closeExpired` — owner reclaim (closeExpired is callable by anyone
  after expiry; funds always return to the owner)
- `spendable(id)` — the amount an agent UI polls before attempting a payment
- Safety: checks-effects-interactions, a reentrancy lock, and a safe-transfer
  helper that tolerates ERC-20s returning `true`, `false`, or nothing.

## Quick start (local)

Requirements: [Foundry](https://getfoundry.sh) ≥ 1.0.

```bash
forge build
forge test -v        # 13 tests: happy path + every limit enforced
```

## Deploy to QDay Aevum testnet

Network: chain ID **44005**, RPC `https://rpc-test.qday.info`,
explorer https://explorer-test.qday.info, gas token **tQDAY** (faucet:
https://faucet.qday.info), payment token **tUSD8**
`0x456569838f1d43009A91ebA4263147Afd7233483` (6 decimals).

```bash
export DEPLOYER_KEY=0x...   # an EOA holding a little tQDAY
forge script script/Deploy.s.sol --rpc-url aevum --broadcast --private-key $DEPLOYER_KEY

# verify the source (Blockscout flow, per QDay docs)
forge verify-contract --chain-id 44005 --verifier blockscout \
  --verifier-url https://explorer-test.qday.info/api \
  <VAULT_ADDRESS> src/AgentPayVault.sol:AgentPayVault
```

## Run the end-to-end demo

`script/DemoFlow.s.sol` replays the full story on testnet: create a mandate
(250 tUSD8/tx, 1,000 budget, 7 days, allowlist on) → fund 1,000 tUSD8 → allowlist
the merchant → **agent pays 200 tUSD8** → owner revokes → 800 tUSD8 return.

```bash
export VAULT=0x... OWNER_KEY=0x... AGENT_KEY=0x... MERCHANT=0x...
forge script script/DemoFlow.s.sol --rpc-url aevum --broadcast
```

### Verify the limits yourself

With a live mandate `id` where you control the agent key, these must **revert**:

```bash
# over the per-transaction cap
cast send $VAULT "pay(uint256,address,uint256,string)" $ID $MERCHANT 250000001 "too much" \
  --rpc-url https://rpc-test.qday.info --private-key $AGENT_KEY
# → OverPerTxCap(250000001, 250000000)

# a payee that is not allowlisted (on an allowlist mandate)
cast send $VAULT "pay(uint256,address,uint256,string)" $ID $RANDOM_ADDR 1000000 "not listed" \
  --rpc-url https://rpc-test.qday.info --private-key $AGENT_KEY
# → PayeeNotAllowed(id, payee)
```

## Deployment (Aevum testnet)

| Item | Value |
|---|---|
| AgentPayVault | *(filled in after the testnet deploy — see STATUS in repo root notes)* |
| Owner / deployer EOA | `0x3BB353511e129F0319585F6791455fC12E534F92` |
| Demo agent EOA | `0xDEccB5a19a63160a4aa4955210C7eCa7E0F8cdEB` |
| tUSD8 | `0x456569838f1d43009A91ebA4263147Afd7233483` |

## Why this matters / roadmap

- **Today**: scoped mandates for a single agent + token, proven on Aevum testnet.
- **Next**: mandate templates for common agent jobs (per-API-call micropayments,
  merchant checkout budgets); multi-agent hierarchies (a manager agent holding a
  mandate that sub-delegates smaller mandates); ERC-4337 session-key integration
  so mandates can bind to QDay's native agent wallets and the stablecoin
  paymaster (gas paid in tUSD8); ERC-8004 agent identity binding once QDay
  publishes the registry addresses.
- **Business model**: a small protocol fee on funded volume for hosted mandate
  management (dashboards, alerts, policy templates) aimed at agent-platform
  operators and merchants who let agents buy on their behalf.

## Tech stack

Solidity 0.8.24 · Foundry (forge, cast, anvil) · QDay Aevum testnet (EVM) · tUSD8 ERC-20

## License

MIT — reuse the mandate pattern freely; it is meant to be ecosystem infrastructure.
