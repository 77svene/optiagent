// SPDX-License-Identifier: MIT
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

/**
 * AgentExecutor - Off-chain trade execution service
 * Simulates HFT trading with bond posting and challenge handling
 */
class AgentExecutor {
  constructor(config) {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl || "http://127.0.0.1:8545");
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);
    this.agentController = null;
    this.driftOracle = null;
    this.fraudProofWindow = null;
    this.agentId = null;
    this.isRunning = false;
    this.pendingChallenges = new Map();
    this.tradeHistory = [];
    this.challengeResponses = new Map();
    
    // Configuration
    this.config = {
      bondAmount: config.bondAmount || ethers.parseEther("1.0"),
      tradeInterval: config.tradeInterval || 5000,
      maxRetries: config.maxRetries || 3,
      challengeResponseTimeout: config.challengeResponseTimeout || 60000,
      strategyHash: config.strategyHash || ethers.keccak256(ethers.toUtf8Bytes("default")),
    };
  }

  /**
   * Initialize contract connections
   */
  async initialize() {
    console.log("[AgentExecutor] Initializing contract connections...");
    
    const abiPath = path.join(__dirname, "../artifacts/contracts");
    if (!fs.existsSync(abiPath)) {
      throw new Error("Contract artifacts not found. Run hardhat compile first.");
    }

    const controllerPath = path.join(abiPath, "AgentController.sol/AgentController.json");
    const driftOraclePath = path.join(abiPath, "DriftOracle.sol/DriftOracle.json");
    const fraudProofPath = path.join(abiPath, "FraudProofWindow.sol/FraudProofWindow.json");

    if (!fs.existsSync(controllerPath) || !fs.existsSync(driftOraclePath) || !fs.existsSync(fraudProofPath)) {
      throw new Error("Required contract artifacts missing. Check compilation output.");
    }

    const controllerAbi = JSON.parse(fs.readFileSync(controllerPath, "utf8")).abi;
    const driftOracleAbi = JSON.parse(fs.readFileSync(driftOraclePath, "utf8")).abi;
    const fraudProofAbi = JSON.parse(fs.readFileSync(fraudProofPath, "utf8")).abi;

    this.agentController = new ethers.Contract(
      this.config.agentControllerAddress || "0x0000000000000000000000000000000000000000",
      controllerAbi,
      this.wallet
    );

    this.driftOracle = new ethers.Contract(
      this.config.driftOracleAddress || "0x0000000000000000000000000000000000000000",
      driftOracleAbi,
      this.wallet
    );

    this.fraudProofWindow = new ethers.Contract(
      this.config.fraudProofWindowAddress || "0x0000000000000000000000000000000000000000",
      fraudProofAbi,
      this.wallet
    );

    console.log("[AgentExecutor] Contract connections established");
    return true;
  }

  /**
   * Register agent with the system
   */
  async registerAgent() {
    console.log("[AgentExecutor] Registering agent...");
    
    const tx = await this.agentController.registerAgent(
      this.wallet.address,
      this.config.bondAmount,
      this.config.strategyHash
    );
    
    const receipt = await tx.wait();
    console.log("[AgentExecutor] Agent registered successfully");
    
    const event = receipt.events?.find(e => e.event === "AgentRegistered");
    if (event) {
      this.agentId = event.args.agentId;
      console.log(`[AgentExecutor] Agent ID: ${this.agentId}`);
    }
    
    return this.agentId;
  }

  /**
   * Execute a simulated trade
   */
  async executeTrade(symbol, side, amount, price) {
    console.log(`[AgentExecutor] Executing trade: ${side} ${amount} ${symbol} @ $${price}`);
    
    const tradeData = {
      symbol,
      side,
      amount,
      price,
      timestamp: Math.floor(Date.now() / 1000),
    };
    
    const tradeHash = ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(tradeData)));
    
    const tx = await this.agentController.executeTrade(
      this.agentId,
      tradeHash,
      this.config.bondAmount
    );
    
    const receipt = await tx.wait();
    console.log(`[AgentExecutor] Trade posted with hash: ${tradeHash}`);
    
    const event = receipt.events?.find(e => e.event === "TradeExecuted");
    if (event) {
      const tradeId = event.args.tradeId;
      const fraudProofWindowEnd = event.args.fraudProofWindowEnd;
      console.log(`[AgentExecutor] Trade ID: ${tradeId}, Fraud proof window ends: ${new Date(Number(fraudProofWindowEnd) * 1000).toISOString()}`);
      
      this.tradeHistory.push({
        tradeId,
        tradeData,
        timestamp: Date.now(),
        status: "pending",
      });
      
      return { tradeId, tradeHash, receipt };
    }
    
    throw new Error("Trade event not found in receipt");
  }

  /**
   * Handle incoming challenge
   */
  async handleChallenge(challengeId, tradeId, challengeProof) {
    console.log(`[AgentExecutor] Handling challenge #${challengeId} for trade #${tradeId}`);
    
    const challengeKey = `${tradeId}-${challengeId}`;
    
    if (this.pendingChallenges.has(challengeKey)) {
      console.log(`[AgentExecutor] Challenge already being handled: ${challengeKey}`);
      return;
    }
    
    this.pendingChallenges.set(challengeKey, {
      challengeId,
      tradeId,
      challengeProof,
      startTime: Date.now(),
    });
    
    try {
      const isValidTrade = await this._validateTrade(tradeId, challengeProof);
      
      if (isValidTrade) {
        await this._submitValidityProof(tradeId, challengeProof);
        console.log(`[AgentExecutor] Validity proof submitted for trade #${tradeId}`);
      } else {
        console.log(`[AgentExecutor] Trade validation failed - bond will be slashed`);
      }
      
      this.pendingChallenges.delete(challengeKey);
      return isValidTrade;
    } catch (error) {
      console.error(`[AgentExecutor] Error handling challenge:`, error);
      this.pendingChallenges.delete(challengeKey);
      throw error;
    }
  }

  /**
   * Validate trade against challenge proof
   */
  async _validateTrade(tradeId, challengeProof) {
    console.log(`[AgentExecutor] Validating trade #${tradeId}`);
    
    try {
      const trade = await this.agentController.getTrade(tradeId);
      
      if (!trade || trade.agent === ethers.ZeroAddress) {
        console.log("[AgentExecutor] Trade not found");
        return false;
      }
      
      const tradeData = JSON.parse(ethers.decodeBytes32String(trade.tradeHash));
      const expectedPrice = tradeData.price;
      const actualPrice = await this._getMarketPrice(tradeData.symbol);
      
      const priceDeviation = Math.abs(Number(expectedPrice) - Number(actualPrice)) / Number(expectedPrice) * 100;
      
      console.log(`[AgentExecutor] Price deviation: ${priceDeviation.toFixed(2)}%`);
      
      if (priceDeviation > 5) {
        console.log("[AgentExecutor] Price deviation exceeds threshold");
        return false;
      }
      
      return true;
    } catch (error) {
      console.error("[AgentExecutor] Validation error:", error);
      return false;
    }
  }

  /**
   * Submit validity proof for challenged trade
   */
  async _submitValidityProof(tradeId, challengeProof) {
    console.log(`[AgentExecutor] Submitting validity proof for trade #${tradeId}`);
    
    const tx = await this.agentController.submitValidityProof(
      tradeId,
      challengeProof,
      this.wallet.address
    );
    
    await tx.wait();
    console.log(`[AgentExecutor] Validity proof submitted successfully`);
    
    return true;
  }

  /**
   * Get market price for symbol (simulated)
   */
  async _getMarketPrice(symbol) {
    console.log(`[AgentExecutor] Fetching market price for ${symbol}`);
    
    try {
      const response = await fetch(`https://api.binance.com/api/v3/ticker/price?symbol=${symbol.toUpperCase()}USDT`);
      const data = await response.json();
      return parseFloat(data.price);
    } catch (error) {
      console.log(`[AgentExecutor] Using simulated price for ${symbol}`);
      return 1000 + Math.random() * 100;
    }
  }

  /**
   * Monitor for challenges
   */
  async monitorChallenges() {
    console.log("[AgentExecutor] Starting challenge monitoring...");
    
    const filter = this.agentController.filters.ChallengeSubmitted();
    
    this.agentController.on(filter, async (challengeId, tradeId, challenger, agent, timestamp, challengeProof, event) => {
      console.log(`[AgentExecutor] Challenge received: #${challengeId} for trade #${tradeId}`);
      
      await this.handleChallenge(
        Number(challengeId),
        Number(tradeId),
        challengeProof
      );
    });
    
    console.log("[AgentExecutor] Challenge monitoring active");
  }

  /**
   * Run trading loop
   */
  async runTradingLoop() {
    console.log("[AgentExecutor] Starting trading loop...");
    this.isRunning = true;
    
    while (this.isRunning) {
      try {
        const symbol = "BTCUSDT";
        const side = Math.random() > 0.5 ? "buy" : "sell";
        const amount = (Math.random() * 0.1).toFixed(4);
        const price = await this._getMarketPrice(symbol);
        
        await this.executeTrade(symbol, side, amount, price);
        
        await new Promise(resolve => setTimeout(resolve, this.config.tradeInterval));
      } catch (error) {
        console.error("[AgentExecutor] Trading loop error:", error);
        await new Promise(resolve => setTimeout(resolve, 5000));
      }
    }
  }

  /**
   * Stop trading loop
   */
  stop() {
    console.log("[AgentExecutor] Stopping trading loop...");
    this.isRunning = false;
    this.agentController.removeAllListeners();
  }

  /**
   * Get agent status
   */
  async getAgentStatus() {
    console.log("[AgentExecutor] Fetching agent status...");
    
    const agent = await this.agentController.agents(this.agentId);
    const metrics = await this.driftOracle.agentMetrics(this.agentId);
    
    return {
      agentId: this.agentId,
      agentAddress: agent.agentAddress,
      bondAmount: agent.bondAmount,
      totalTrades: agent.totalTrades,
      successfulTrades: agent.successfulTrades,
      challengedTrades: agent.challengedTrades,
      isActive: agent.isActive,
      driftScore: agent.driftScore,
      totalPnL: metrics.totalPnL,
      totalExecutionTime: metrics.totalExecutionTime,
    };
  }

  /**
   * Get pending challenges
   */
  getPendingChallenges() {
    const pending = [];
    for (const [key, data] of this.pendingChallenges.entries()) {
      pending.push({
        key,
        ...data,
        elapsed: Date.now() - data.startTime,
      });
    }
    return pending;
  }
}

module.exports = { AgentExecutor };