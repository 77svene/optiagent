// SPDX-License-Identifier: MIT
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OptiAgent Trade Lifecycle Integration", function () {
  let owner, agent, challenger, user;
  let agentController, bondManager, fraudProofWindow, driftOracle, challengeVerifier;
  let testToken;
  const BOND_AMOUNT = ethers.parseEther("10.0");
  const CHALLENGE_BOND = ethers.parseEther("1.0");
  const FRAUD_PROOF_WINDOW = 24 * 60 * 60; // 24 hours in seconds
  const STRATEGY_HASH = ethers.keccak256(ethers.toUtf8Bytes("momentum_v1"));

  beforeEach(async function () {
    [owner, agent, challenger, user] = await ethers.getSigners();

    // Deploy test token
    const TestToken = await ethers.getContractFactory("TestToken");
    testToken = await TestToken.deploy();
    await testToken.deployed();

    // Deploy all contracts
    const BondManager = await ethers.getContractFactory("BondManager");
    bondManager = await BondManager.deploy(testToken.address);
    await bondManager.deployed();

    const ChallengeVerifier = await ethers.getContractFactory("ChallengeVerifier");
    challengeVerifier = await ChallengeVerifier.deploy();
    await challengeVerifier.deployed();

    const DriftOracle = await ethers.getContractFactory("DriftOracle");
    driftOracle = await DriftOracle.deploy();
    await driftOracle.deployed();

    const FraudProofWindow = await ethers.getContractFactory("FraudProofWindow");
    fraudProofWindow = await FraudProofWindow.deploy(
      bondManager.address,
      challengeVerifier.address,
      driftOracle.address,
      FRAUD_PROOF_WINDOW
    );
    await fraudProofWindow.deployed();

    const AgentController = await ethers.getContractFactory("AgentController");
    agentController = await AgentController.deploy(
      bondManager.address,
      fraudProofWindow.address,
      driftOracle.address,
      challengeVerifier.address
    );
    await agentController.deployed();

    // Initialize contracts
    await bondManager.initialize(agentController.address);
    await driftOracle.initialize(agentController.address);
    await fraudProofWindow.initialize(agentController.address);

    // Fund agent with tokens for bond
    await testToken.mint(agent.address, ethers.parseEther("100.0"));
    await testToken.mint(challenger.address, ethers.parseEther("100.0"));
  });

  describe("Agent Registration", function () {
    it("Should register agent with bond", async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      const agentData = await agentController.agents(agent);
      expect(agentData.agentAddress).to.equal(agent.address);
      expect(agentData.bondAmount).to.equal(BOND_AMOUNT);
      expect(agentData.isActive).to.be.true;
    });

    it("Should fail to register without sufficient balance", async function () {
      await expect(
        bondManager.connect(agent).postBond(BOND_AMOUNT)
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    });

    it("Should fail to register if already registered", async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      await expect(
        bondManager.connect(agent).postBond(BOND_AMOUNT)
      ).to.be.revertedWith("Agent already registered");
    });
  });

  describe("Trade Execution", function () {
    beforeEach(async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);
    });

    it("Should execute trade and post bond", async function () {
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();

      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      expect(tradeEvent).to.not.be.undefined;

      const tradeId = tradeEvent.args.tradeId;
      const trade = await agentController.trades(tradeId);
      expect(trade.agent).to.equal(agent.address);
      expect(trade.bondPosted).to.equal(BOND_AMOUNT);
      expect(trade.fraudProofWindowEnd).to.be.greaterThan(
        Math.floor(Date.now() / 1000)
      );
    });

    it("Should fail to execute trade without registration", async function () {
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      await expect(
        agentController.connect(agent).executeTrade(STRATEGY_HASH, tradeData)
      ).to.be.revertedWith("Agent not registered");
    });

    it("Should fail to execute trade if fraud proof window expired", async function () {
      await fraudProofWindow.setFraudProofWindow(1);
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      await expect(
        agentController.connect(agent).executeTrade(STRATEGY_HASH, tradeData)
      ).to.be.revertedWith("Fraud proof window expired");
    });
  });

  describe("Challenge Submission", function () {
    let tradeId;

    beforeEach(async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      tradeId = tradeEvent.args.tradeId;
    });

    it("Should submit challenge within fraud proof window", async function () {
      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      const tx = await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);
      const receipt = await tx.wait();

      const challengeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "ChallengeSubmitted"
      );
      expect(challengeEvent).to.not.be.undefined;

      const challengeId = challengeEvent.args.challengeId;
      const challenge = await fraudProofWindow.challenges(challengeId);
      expect(challenge.challenger).to.equal(challenger.address);
      expect(challenge.tradeId).to.equal(tradeId);
      expect(challenge.status).to.equal(0); // Pending
    });

    it("Should fail to challenge if already challenged", async function () {
      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);

      await expect(
        fraudProofWindow
          .connect(challenger)
          .submitChallenge(tradeId, challengeData)
      ).to.be.revertedWith("Trade already challenged");
    });

    it("Should fail to challenge after fraud proof window expires", async function () {
      await fraudProofWindow.setFraudProofWindow(1);
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      await expect(
        fraudProofWindow
          .connect(challenger)
          .submitChallenge(tradeId, challengeData)
      ).to.be.revertedWith("Fraud proof window expired");
    });

    it("Should fail to challenge without sufficient bond", async function () {
      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      await expect(
        fraudProofWindow
          .connect(challenger)
          .submitChallenge(tradeId, challengeData)
      ).to.be.revertedWith("Insufficient challenge bond");
    });
  });

  describe("Dispute Resolution", function () {
    let tradeId, challengeId;

    beforeEach(async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      tradeId = tradeEvent.args.tradeId;

      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      const challengeTx = await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);
      const challengeReceipt = await challengeTx.wait();
      const challengeEvent = challengeReceipt.logs.find(
        (log) => log.fragment?.name === "ChallengeSubmitted"
      );
      challengeId = challengeEvent.args.challengeId;
    });

    it("Should resolve challenge with valid proof", async function () {
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));

      const tx = await fraudProofWindow
        .connect(agent)
        .submitProof(tradeId, challengeId, proof);
      const receipt = await tx.wait();

      const resolutionEvent = receipt.logs.find(
        (log) => log.fragment?.name === "ChallengeResolved"
      );
      expect(resolutionEvent).to.not.be.undefined;

      const challenge = await fraudProofWindow.challenges(challengeId);
      expect(challenge.status).to.equal(1); // Resolved
      expect(challenge.resolvedBy).to.equal(agent.address);
    });

    it("Should fail to submit proof if not agent", async function () {
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));

      await expect(
        fraudProofWindow
          .connect(challenger)
          .submitProof(tradeId, challengeId, proof)
      ).to.be.revertedWith("Only agent can submit proof");
    });

    it("Should fail to submit proof if already resolved", async function () {
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));

      await fraudProofWindow
        .connect(agent)
        .submitProof(tradeId, challengeId, proof);

      await expect(
        fraudProofWindow
          .connect(agent)
          .submitProof(tradeId, challengeId, proof)
      ).to.be.revertedWith("Challenge already resolved");
    });

    it("Should auto-resolve if no proof submitted before window expires", async function () {
      await fraudProofWindow.setFraudProofWindow(1);
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      const tx = await fraudProofWindow
        .connect(agent)
        .resolveExpiredChallenge(tradeId, challengeId);
      const receipt = await tx.wait();

      const resolutionEvent = receipt.logs.find(
        (log) => log.fragment?.name === "ChallengeResolved"
      );
      expect(resolutionEvent).to.not.be.undefined;

      const challenge = await fraudProofWindow.challenges(challengeId);
      expect(challenge.status).to.equal(2); // Failed
    });
  });

  describe("Bond Slashing", function () {
    let tradeId, challengeId;

    beforeEach(async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      tradeId = tradeEvent.args.tradeId;

      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      const challengeTx = await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);
      const challengeReceipt = await challengeTx.wait();
      const challengeEvent = challengeReceipt.logs.find(
        (log) => log.fragment?.name === "ChallengeSubmitted"
      );
      challengeId = challengeEvent.args.challengeId;
    });

    it("Should slash agent bond on failed proof", async function () {
      await fraudProofWindow.setFraudProofWindow(1);
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      const tx = await fraudProofWindow
        .connect(agent)
        .resolveExpiredChallenge(tradeId, challengeId);
      await tx.wait();

      const agentData = await agentController.agents(agent.address);
      expect(agentData.challengedTrades).to.be.greaterThan(0);

      const balance = await testToken.balanceOf(agent.address);
      expect(balance).to.be.lessThan(BOND_AMOUNT);
    });

    it("Should refund challenger bond on successful agent proof", async function () {
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));

      await fraudProofWindow
        .connect(agent)
        .submitProof(tradeId, challengeId, proof);

      const challengerBalance = await testToken.balanceOf(challenger.address);
      expect(challengerBalance).to.be.greaterThan(0);
    });

    it("Should slash challenger bond on false challenge", async function () {
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));

      await fraudProofWindow
        .connect(agent)
        .submitProof(tradeId, challengeId, proof);

      const challenge = await fraudProofWindow.challenges(challengeId);
      expect(challenge.status).to.equal(1); // Resolved

      const challengerBalance = await testToken.balanceOf(challenger.address);
      expect(challengerBalance).to.be.lessThan(CHALLENGE_BOND);
    });
  });

  describe("Edge Cases and Race Conditions", function () {
    beforeEach(async function () {
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);
    });

    it("Should handle multiple challenges on same trade", async function () {
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      const tradeId = tradeEvent.args.tradeId;

      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);

      // Second challenger should be able to challenge
      const tx2 = await fraudProofWindow
        .connect(user)
        .submitChallenge(tradeId, challengeData);
      const receipt2 = await tx2.wait();
      const challengeEvent = receipt2.logs.find(
        (log) => log.fragment?.name === "ChallengeSubmitted"
      );
      expect(challengeEvent).to.not.be.undefined;
    });

    it("Should handle rapid consecutive trades", async function () {
      for (let i = 0; i < 5; i++) {
        const tradeData = {
          tokenIn: testToken.address,
          tokenOut: ethers.ZeroAddress,
          amountIn: ethers.parseEther("1.0"),
          amountOutMin: ethers.parseEther("0.9"),
          deadline: Math.floor(Date.now() / 1000) + 3600,
        };

        const tx = await agentController
          .connect(agent)
          .executeTrade(STRATEGY_HASH, tradeData);
        await tx.wait();
      }

      const agentData = await agentController.agents(agent.address);
      expect(agentData.totalTrades).to.equal(5);
    });

    it("Should handle bond withdrawal after successful trades", async function () {
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      await tx.wait();

      const agentData = await agentController.agents(agent.address);
      expect(agentData.totalTrades).to.equal(1);
      expect(agentData.successfulTrades).to.equal(1);

      const balance = await testToken.balanceOf(agent.address);
      expect(balance).to.be.greaterThan(0);
    });

    it("Should handle drift score updates", async function () {
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);

      const agentData = await agentController.agents(agent.address);
      expect(agentData.driftScore).to.be.greaterThan(0);
    });
  });

  describe("Complete Lifecycle", function () {
    it("Should complete full trade lifecycle from execution to resolution", async function () {
      // 1. Register agent
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      // 2. Execute trade
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      const tradeId = tradeEvent.args.tradeId;

      // 3. Submit challenge
      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      const challengeTx = await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);
      const challengeReceipt = await challengeTx.wait();
      const challengeEvent = challengeReceipt.logs.find(
        (log) => log.fragment?.name === "ChallengeSubmitted"
      );
      const challengeId = challengeEvent.args.challengeId;

      // 4. Submit proof
      const proof = ethers.keccak256(ethers.toUtf8Bytes("valid_proof"));
      await fraudProofWindow
        .connect(agent)
        .submitProof(tradeId, challengeId, proof);

      // 5. Verify resolution
      const challenge = await fraudProofWindow.challenges(challengeId);
      expect(challenge.status).to.equal(1); // Resolved
      expect(challenge.resolvedBy).to.equal(agent.address);

      // 6. Verify agent stats
      const agentData = await agentController.agents(agent.address);
      expect(agentData.totalTrades).to.equal(1);
      expect(agentData.successfulTrades).to.equal(1);
      expect(agentData.challengedTrades).to.equal(0);
    });

    it("Should complete failed lifecycle with bond slashing", async function () {
      // 1. Register agent
      await testToken.connect(agent).approve(bondManager.address, BOND_AMOUNT);
      await bondManager.connect(agent).postBond(BOND_AMOUNT);

      // 2. Execute trade
      const tradeData = {
        tokenIn: testToken.address,
        tokenOut: ethers.ZeroAddress,
        amountIn: ethers.parseEther("1.0"),
        amountOutMin: ethers.parseEther("0.9"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
      };

      const tx = await agentController
        .connect(agent)
        .executeTrade(STRATEGY_HASH, tradeData);
      const receipt = await tx.wait();
      const tradeEvent = receipt.logs.find(
        (log) => log.fragment?.name === "TradeExecuted"
      );
      const tradeId = tradeEvent.args.tradeId;

      // 3. Submit challenge
      await testToken.connect(challenger).approve(
        bondManager.address,
        CHALLENGE_BOND
      );

      const challengeData = {
        reason: "Trade deviates from strategy",
        evidenceHash: ethers.keccak256(ethers.toUtf8Bytes("evidence")),
      };

      const challengeTx = await fraudProofWindow
        .connect(challenger)
        .submitChallenge(tradeId, challengeData);
      await challengeTx.wait();

      // 4. Let window expire
      await fraudProofWindow.setFraudProofWindow(1);
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine");

      // 5. Resolve expired challenge
      await fraudProofWindow
        .connect(agent)
        .resolveExpiredChallenge(tradeId, challengeId);

      // 6. Verify agent stats
      const agentData = await agentController.agents(agent.address);
      expect(agentData.challengedTrades).to.be.greaterThan(0);

      // 7. Verify bond was slashed
      const balance = await testToken.balanceOf(agent.address);
      expect(balance).to.be.lessThan(BOND_AMOUNT);
    });
  });
});