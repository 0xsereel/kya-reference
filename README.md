# kya-reference

[![CI](https://github.com/<GITHUB_USER>/kya-reference/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/<GITHUB_USER>/kya-reference/actions/workflows/ci.yml)

**This is reference code. It is unaudited, is not intended for production, and comes with no warranty. Do not deploy it to a network that holds real value.**

Companion repo to the post [Know Your Agent for Tokenized Securities](<BLOG_POST_URL>). It demonstrates sections 3 and 4 of the post on a real ERC-3643 (T-REX) stack: an agent's wallet is registered under its principal's ONCHAINID, the link is backed by a trusted-issuer claim that references an ERC-8004 agent identity, and a compliance module (`MandateModule`) enforces the principal's mandate on every transfer the agent sends.

## Quickstart

```sh
git clone --recursive https://github.com/<GITHUB_USER>/kya-reference.git
cd kya-reference && forge build
forge test
```

You need [Foundry](https://book.getfoundry.sh/getting-started/installation) and nothing else. The tests pass and fail on cue for each rule in the post.

## Two meanings of "agent"

T-REX already uses the word "agent" for an issuer-side operator with freeze and forced-transfer powers. The post uses it for an AI agent acting for a principal. This repo keeps them apart:

- `trexAgent` is the T-REX token agent (issuer operator). In the tests it is a separate address from `issuer`, the token owner, and is added as a token agent for clarity.
- `aiAgent` is the mandated wallet that acts for a principal.

Unless a sentence says otherwise, "agent" in the contracts means the AI agent.

## Mandate lifecycle

The token owner registers the agent wallet in the token's identity registry under the principal's ONCHAINID, so the agent's holdings resolve to the principal. A trusted claim issuer signs an `AGENT_MANDATE` claim onto the principal's identity, binding the agent wallet, its ERC-8004 `agentId`, a hash of the mandate terms, and an expiry. The owner then calls `setMandate` through `ModularCompliance.callModuleFunction`, and the module checks the identity link, the claim, the issuer's trust, and the `agentId` before storing the mandate. From then on, each transfer the agent sends must stay within `maxPerTransfer` and the UTC-day `dailyCap`, and must arrive before `expiry`. Senders with no mandate are untouched. The principal (via a management key on their ONCHAINID) or the issuer can revoke at any time. Revocation flags the mandate and keeps the record. The issuer's existing controls, freezes and forced transfers, still sit above the mandate. `test/integration/AgentTransfers.t.sol` walks each of these steps.

## Pinned versions

| Component | Version |
|---|---|
| T-REX (ERC-3643) | 4.1.6 |
| ONCHAINID | 2.1.0 (the version T-REX 4.1.6 locks) |
| OpenZeppelin (4.x) | 4.9.3 (the version T-REX 4.1.6 locks) |
| forge-std | v1.9.7 |
| Solidity | 0.8.17, optimizer 200 runs |
| ERC-8004 (mock) | Draft as published at eips.ethereum.org, created 2025-08-13, read 2026-09-23 (the draft has no revision number) |

Versions are fixed and are not meant to float.

## Behavior notes

- **Forced transfers count toward the daily cap.** T-REX's `forcedTransfer` calls `compliance.transferred` like any transfer, so the module cannot tell it apart. The issuer's forced transfer from an agent wallet is never blocked, even by a revoked or expired mandate, but the amount is recorded as that day's spend.
- **One mandate claim per issuer and principal.** ONCHAINID keys a claim by issuer and topic, so a second `AGENT_MANDATE` claim from the same issuer on the same identity replaces the first.
- **Test fixture simplification.** The fixture makes only KYC a required claim topic. T-REX requires every holder to carry every required topic, so requiring `AGENT_MANDATE` would make ordinary investors unverifiable. A real deployment should choose its required topics deliberately.

## Gas

Added gas of `moduleCheck` plus `moduleTransferAction` on an agent transfer, compared with an investor transfer: TBD (measured in Stage 11).

## Scope

In scope: `MandateModule`, a minimal mock of the ERC-8004 Identity Registry, the mandate claim format, a T-REX deployment fixture, and unit, integration, fuzz, and invariant tests. Out of scope: the ERC-8004 Reputation and Validation registries, the zero-knowledge private mandate flow from section 5 (represented only by the `IPrivateMandateVerifier` interface stub), counterparty and asset allowlists, and public-network deployment scripts.

## License

[MIT](LICENSE)

## Contributing

Issues and pull requests are welcome. Please run `forge fmt` and `forge test` before opening a PR, and keep the pinned dependency versions unchanged unless the change is about them.
