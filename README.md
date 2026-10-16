OmniVM ⚡
Production-grade EIP-1153 Omnichain Execution VM & Intent Solver powered by LayerZero V2.
OmniVM is an open-source, modular cross-chain execution container and intent solver framework. It uses EIP-1153 Transient Storage to mount and clear cross-chain caller context (xMsgSender and xMsgOrigin) across execution boundaries without permanent storage gas overhead.

🛠 Repository Architecture
contracts/: Hardened Solidity contracts, Foundry test suite (including adversarial return-data bomb and reentrancy protection), and CREATE2 deployment scripts.
sdk/: Viem/Wagmi TypeScript SDK with invariant checkers, ERC-1271/EOA signature verification, and dynamic LayerZero V2 Type 3 option encoders.
frontend/: Next.js / Wagmi interface with a multi-mode instruction builder.
relayer/: Automated off-chain intent solver daemon.

🧪 Quickstart & Testing
1. Smart Contract Tests (Foundry)
To run the core Solidity contracts and adversarial test suite locally via Foundry, run:
cd contracts
forge test -vvv

2. Local Anvil Fork Integration Tests (Vitest)
To spin up a local Anvil fork of Arbitrum Sepolia and execute the full TypeScript solver integration pipeline, run:
cd sdk
npm test

📄 License
MIT
