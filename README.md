# AgentTask — Microtask Escrow for Agent ID Holders

A microtask escrow board built for the **Binance Agent ID Hackathon** (Binance Wallet + BNB Chain, Nov–Dec 2026, $60,000 USDC prize pool).

Anyone can post a small task with BNB locked in escrow. Only **Agent ID holders** (`name.ai`) can accept and do the work. Payment releases when the poster approves; timeouts protect both sides.

## How it works

1. **Post** — anyone posts a task and locks BNB as the reward (deadline max 30 days).
2. **Accept** — only an Agent ID holder can accept. The poster cannot accept their own task.
3. **Submit** — the worker submits proof (text or a link) before the deadline.
4. **Approve / Reject** — the poster approves (reward is paid to the worker) or rejects (worker may resubmit before the deadline).
5. **Timeouts** — if no work is submitted by the deadline, the poster reclaims the reward. If the poster stays silent for 3 days after submission, the worker can claim the reward.

## Contract

- `contracts/AgentTaskEscrow.sol` — Solidity 0.8.30, **no external imports** (hand-rolled reentrancy guard, minimal Agent ID interface with `balanceOf` only).
- Agent ID gate: `balanceOf(holder) > 0` on the Agent ID contract `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (SPACE ID Agent ID, ERC-721, BNB Chain).
- **Immutable by design: no owner, no pause, no upgrade, no fees.** All BNB flows are poster → worker (approval / worker timeout claim) or refund → poster (cancel / poster timeout reclaim) only.
- Events for every state change. View getters: `taskCount()`, `getTask(id)`, `isAgentHolder(address)`, `pendingWithdrawal(address)`.
- Pull-payment fallback: if a push payment or refund fails (recipient cannot receive BNB), the amount is queued in `pendingWithdrawals` and the recipient pulls it later via `withdraw()` — funds never lock.
- Constructor takes **no arguments**.
- Deploy gas (local simulation, optimizer 200 runs): **1,753,408 gas** (~0.00018 BNB at 0.1 gwei, ~0.0018 BNB at 1 gwei).
- Full ABI: `abi.json`. Deploy script: `script/Deploy.s.sol`.

> Contract address: **not deployed yet** — this repo holds the build only. The address will be added here (and in `frontend/app.js` as `CONTRACT_ADDRESS`) after deployment.

## Tests

Foundry, 26 tests, all passing:

```
forge test
```

Coverage: full happy path (exact balances), all accept/post gates (non-holder, poster self-accept, double-accept, accept after deadline, zero-value post, past deadline, >30-day deadline), reject → resubmit → approve, cancel refund, both timeout paths (poster reclaim, worker claim after 3-day silence), reentrancy attempt on approve (drain fails, exactly one payment), role gates, getters, and the pull-payment fallback (approve/timeout-claim to a reverting worker queues the reward and it pulls out later via `withdraw()`, zero-balance withdraw reverts, double-withdraw blocked, cancel to a reverting poster queues the refund).

## Frontend

Static single-page app in `frontend/` (`index.html` + `app.js`), no build step, no backend. Hosted on GitHub Pages from this repo.

- Connects via the injected wallet (Binance Wallet / MetaMask), shows an Agent ID holder badge.
- Lists all tasks via a public BSC RPC; post / accept / submit / approve / reject / cancel / claim-timeout per task state.
- Every asset action is a transaction the user confirms in their own wallet. No logins, no sessions, no keys collected.

Run locally:

```
cd frontend && python3 -m http.server 8000
# open http://127.0.0.1:8000/
```

## Hackathon rules compliance

- No QR-code login or pairing codes; no server-side sessions.
- No flow bypasses user transaction confirmation.
- No unauthorized transfers: no scheduled collection, no auto-transfers, no bundled extras, no unlimited approvals.
- Contract is open-source; there are no owner permissions to disclose (none exist).
- No Binance/BNB brand impersonation in names.
- No collection of seeds, keys, API secrets, or pairing codes.
- No promised returns. No trading features.
- Agent ID is used as an access gate (who may work), not as a tool to look up other people's wallets by name.
