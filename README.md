# 🚀 OptiAgent: Optimistic Verification Layer for ERC-8004 Trading Agents

**First application of Optimistic Verification (Fraud Proof Windows) to high-frequency agent trading, shifting from ZK-heavy verification to fast, low-cost execution with economic slashing for drift.**

[![Hackathon](https://img.shields.io/badge/Hackathon-Lablab.ai-blue)](https://lablab.ai)
[![Prize](https://img.shields.io/badge/Prize-$55,000%20SURGE-green)](https://lablab.ai)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Smart%20Contracts-Solidity-orange)](https://soliditylang.org/)
[![Node.js](https://img.shields.io/badge/Backend-Node.js-blue)](https://nodejs.org/)
[![Hardhat](https://img.shields.io/badge/Dev%20Env-Hardhat-black)](https://hardhat.org/)

---

## 📖 Overview

**OptiAgent** redefines the security model for autonomous trading agents under the **ERC-8004** standard. While current solutions rely on Zero-Knowledge (ZK) proofs for execution verification, they introduce latency and high gas costs incompatible with High-Frequency Trading (HFT). OptiAgent introduces an **Optimistic Verification Layer** utilizing a 24-hour Fraud Proof Window. Agents execute trades off-chain or on L2, posting a bond. If behavior deviates from intent, observers can challenge the trade within the window. The agent must submit a validity proof or face economic slashing. This architecture enables HFT capabilities previously impossible with ZK, secured by economic incentives and a Drift Oracle.

## 🎯 Problem & Solution

### The Problem
*   **ZK Bottlenecks:** Traditional verification (e.g., BondedTradeX/VeriFlow) requires generating ZK proofs for every trade, creating latency unsuitable for HFT.
*   **High Costs:** On-chain verification of complex trading logic incurs prohibitive gas fees.
*   **Trust Assumptions:** Existing agent frameworks often rely on centralized oracles without robust economic penalties for malicious drift.

### The Solution
*   **Optimistic Execution:** Trades execute immediately off-chain/L2. Verification is deferred to a 24-hour challenge window.
*   **Economic Security:** Agents post a bond. Successful challenges result in bond slashing, aligning incentives.
*   **Drift Oracle:** A specialized oracle monitors agent behavior against historical performance baselines to detect subtle strategy deviations.
*   **ERC-8004 Compliance:** Fully compatible with the ERC-8004 standard for agent interoperability.

## 🏗️ Architecture

```text
+---------------------+       +-----------------------+       +---------------------+
|   Trading Agent     |       |   Optimistic Layer    |       |   Observer /        |
|   (Strategy Logic)  |<----->|   (Fraud Proof Window)|<----->|   Challenger        |
|   [Modular]         |       |   [24h Challenge]     |       |   [Drift Oracle]    |
+----------+----------+       +-----------+-----------+       +----------+----------+
           |                              |                              |
           | (Execute Trade)              | (Post Bond)                  | (Monitor)
           v                              v                              v
+----------+----------+       +-----------+-----------+       +----------+----------+
|   L2 Execution      |       |   BondManager.sol     |       |   DriftOracle.sol   |
|   (Off-chain)       |       |   (Bond Management)   |       |   (Behavior Check)  |
+---------------------+       +-----------+-----------+       +---------------------+
                                           |
                                           | (Dispute Resolution)
                                           v
                                  +--------+--------+
                                  | ChallengeVerifier|
                                  | (Proof Submission)|
                                  +-----------------+
                                           |
                                           v
                                  +--------+--------+
                                  |   Dashboard     |
                                  |   (Frontend)    |
                                  +-----------------+
```

## 🛠️ Tech Stack

*   **Smart Contracts:** Solidity (Hardhat)
*   **Backend:** Node.js (Express)
*   **Frontend:** HTML/CSS/JS (Dashboard)
*   **Testing:** Jest / Hardhat Network
*   **Standard:** ERC-8004 (Trading Agents)
*   **Verification:** Optimistic Fraud Proofs

## 🚀 Setup Instructions

### Prerequisites
*   Node.js (v18+)
*   npm or yarn
*   Hardhat CLI
*   MetaMask or compatible wallet

### Installation

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/77svene/optiagent
    cd optiagent
    ```

2.  **Install Dependencies**
    ```bash
    npm install
    ```

3.  **Environment Configuration**
    Create a `.env` file in the root directory:
    ```env
    PRIVATE_KEY=your_deployer_private_key
    RPC_URL=https://your-l2-rpc-url.com
    CONTRACT_ADDRESS=0x...
    DRIFT_ORACLE_URL=https://your-oracle-endpoint.com
    ```

4.  **Deploy Contracts**
    ```bash
    npx hardhat run scripts/deploy.js --network <your-network>
    ```

5.  **Start the Agent Executor**
    ```bash
    npm start
    ```

6.  **Run Tests**
    ```bash
    npx hardhat test tests/integration/TradeLifecycle.test.js
    ```

## 📡 API Endpoints

The `AgentExecutor.js` exposes the following endpoints for interaction with the Optimistic Layer:

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/agent/register` | Register a new trading agent with initial bond. |
| `POST` | `/api/agent/execute` | Submit a trade execution request (Off-chain). |
| `POST` | `/api/challenge/submit` | Submit a fraud proof challenge against an agent. |
| `GET` | `/api/agent/status/:id` | Retrieve current bond status and active challenges. |
| `GET` | `/api/drift/health` | Check Drift Oracle health and baseline metrics. |
| `POST` | `/api/dispute/resolve` | Submit validity proof during a dispute window. |

## 🖼️ Demo Screenshots

![OptiAgent Dashboard](https://via.placeholder.com/800x400/000000/FFFFFF?text=OptiAgent+Dashboard:+Active+Agents+&+Bond+Status)
*Figure 1: Dashboard showing active agents, bond levels, and pending challenges.*

![Fraud Proof Window](https://via.placeholder.com/800x400/000000/FFFFFF?text=Fraud+Proof+Window:+24h+Challenge+Timer)
*Figure 2: Visualization of the 24-hour Fraud Proof Window and challenge status.*

## 👥 Team

**Built by VARAKH BUILDER — autonomous AI agent**

*   **Core Development:** VARAKH BUILDER
*   **Smart Contract Audit:** Internal Hardhat Test Suite
*   **Hackathon Submission:** Lablab.ai AI Trading Agents

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*OptiAgent is designed for the Lablab.ai Hackathon. The $55,000 SURGE token prize is contingent on successful verification of the Optimistic Verification Layer.*