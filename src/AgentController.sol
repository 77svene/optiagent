// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title OptiAgent - Optimistic Verification Layer for ERC-8004 Trading Agents
 * @notice Optimistic verification with 24-hour fraud proof window for HFT trading
 * @dev Economic slashing replaces ZK proofs for faster execution
 */
contract AgentController is ReentrancyGuard {
    using Address for address;
    using ECDSA for bytes32;

    // === CORE STATE ===
    struct Agent {
        address agentAddress;
        uint256 bondAmount;
        uint256 lastTradeTimestamp;
        uint256 totalTrades;
        uint256 successfulTrades;
        uint256 challengedTrades;
        bool isActive;
        bytes32 strategyHash;
        uint256 driftScore;
    }

    struct Trade {
        uint256 tradeId;
        address agent;
        bytes32 tradeHash;
        uint256 timestamp;
        uint256 bondPosted;
        uint256 fraudProofWindowEnd;
        bool isChallenged;
        bool isResolved;
        bytes32 challengeProof;
        address challenger;
    }

    struct Challenge {
        uint256 challengeId;
        uint256 tradeId;
        address agent;
        address challenger;
        bytes32 challengeReason;
        uint256 timestamp;
        bool resolved;
        bool challengeValid;
    }

    // === STORAGE ===
    mapping(address => Agent) public agents;
    mapping(uint256 => Trade) public trades;
    mapping(uint256 => Challenge) public challenges;
    mapping(address => uint256) public agentTradeCount;
    mapping(address => uint256) public agentBondBalance;
    mapping(address => bool) public isRegisteredAgent;

    uint256 public tradeCounter;
    uint256 public challengeCounter;
    uint256 public constant FRAUD_PROOF_WINDOW = 24 hours;
    uint256 public constant MIN_BOND = 1000 ether;
    uint256 public constant SLASH_PERCENTAGE = 50;
    address public owner;
    address public bondToken;

    // === EVENTS ===
    event AgentRegistered(address indexed agent, uint256 bondAmount);
    event TradeExecuted(uint256 indexed tradeId, address indexed agent, bytes32 tradeHash);
    event BondPosted(address indexed agent, uint256 amount);
    event BondSlashed(address indexed agent, uint256 amount, uint256 tradeId);
    event ChallengeSubmitted(uint256 indexed challengeId, uint256 indexed tradeId, address indexed challenger);
    event ChallengeResolved(uint256 indexed challengeId, bool valid);

    // === MODIFIERS ===
    modifier onlyOwner() {
        require(msg.sender == owner, "AgentController: not owner");
        _;
    }

    modifier agentExists(address _agent) {
        require(isRegisteredAgent[_agent], "AgentController: agent not registered");
        _;
    }

    // === CONSTRUCTOR ===
    constructor(address _bondToken) {
        require(_bondToken != address(0), "AgentController: invalid token");
        owner = msg.sender;
        bondToken = _bondToken;
    }

    // === AGENT REGISTRATION ===
    function registerAgent(bytes32 _strategyHash) external payable returns (bool) {
        require(!isRegisteredAgent[msg.sender], "AgentController: already registered");
        require(msg.value >= MIN_BOND, "AgentController: insufficient bond");

        Agent storage agent = agents[msg.sender];
        agent.agentAddress = msg.sender;
        agent.bondAmount = msg.value;
        agent.strategyHash = _strategyHash;
        agent.isActive = true;
        agent.driftScore = 0;
        agent.lastTradeTimestamp = 0;
        agent.totalTrades = 0;
        agent.successfulTrades = 0;
        agent.challengedTrades = 0;

        isRegisteredAgent[msg.sender] = true;
        agentBondBalance[msg.sender] = msg.value;

        emit AgentRegistered(msg.sender, msg.value);
        return true;
    }

    // === BOND MANAGEMENT ===
    function postAdditionalBond(uint256 _amount) external payable agentExists(msg.sender) {
        require(_amount > 0, "AgentController: amount must be positive");
        Agent storage agent = agents[msg.sender];
        require(agent.isActive, "AgentController: agent not active");

        uint256 newBond = agent.bondAmount + _amount;
        agent.bondAmount = newBond;
        agentBondBalance[msg.sender] = newBond;

        emit BondPosted(msg.sender, _amount);
    }

    function withdrawBond(uint256 _amount) external agentExists(msg.sender) {
        Agent storage agent = agents[msg.sender];
        require(agent.isActive, "AgentController: agent not active");
        require(_amount > 0, "AgentController: amount must be positive");
        require(_amount <= agent.bondAmount, "AgentController: insufficient bond");

        agent.bondAmount -= _amount;
        agentBondBalance[msg.sender] -= _amount;

        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        require(success, "AgentController: withdrawal failed");
    }

    // === TRADE EXECUTION ===
    function executeTrade(bytes32 _tradeHash, bytes calldata _tradeData) external payable agentExists(msg.sender) nonReentrant returns (uint256) {
        Agent storage agent = agents[msg.sender];
        require(agent.isActive, "AgentController: agent not active");

        uint256 requiredBond = calculateRequiredBond(_tradeHash);
        require(msg.value >= requiredBond, "AgentController: insufficient trade bond");

        tradeCounter++;
        uint256 tradeId = tradeCounter;

        Trade storage trade = trades[tradeId];
        trade.tradeId = tradeId;
        trade.agent = msg.sender;
        trade.tradeHash = _tradeHash;
        trade.timestamp = block.timestamp;
        trade.bondPosted = msg.value;
        trade.fraudProofWindowEnd = block.timestamp + FRAUD_PROOF_WINDOW;
        trade.isChallenged = false;
        trade.isResolved = false;
        trade.challengeProof = bytes32(0);
        trade.challenger = address(0);

        agent.lastTradeTimestamp = block.timestamp;
        agent.totalTrades++;
        agentTradeCount[msg.sender]++;

        emit TradeExecuted(tradeId, msg.sender, _tradeHash);
        return tradeId;
    }

    function calculateRequiredBond(bytes32 _tradeHash) public view returns (uint256) {
        Agent storage agent = agents[msg.sender];
        uint256 baseBond = MIN_BOND / 10;
        uint256 driftMultiplier = 1 + (agent.driftScore / 100);
        return baseBond * driftMultiplier;
    }

    // === CHALLENGE SUBMISSION ===
    function submitChallenge(uint256 _tradeId, bytes32 _challengeReason) external payable returns (uint256) {
        Trade storage trade = trades[_tradeId];
        require(trade.tradeId != 0, "AgentController: trade does not exist");
        require(!trade.isChallenged, "AgentController: trade already challenged");
        require(!trade.isResolved, "AgentController: trade already resolved");
        require(block.timestamp <= trade.fraudProofWindowEnd, "AgentController: fraud proof window expired");

        challengeCounter++;
        uint256 challengeId = challengeCounter;

        Challenge storage challenge = challenges[challengeId];
        challenge.challengeId = challengeId;
        challenge.tradeId = _tradeId;
        challenge.agent = trade.agent;
        challenge.challenger = msg.sender;
        challenge.challengeReason = _challengeReason;
        challenge.timestamp = block.timestamp;
        challenge.resolved = false;
        challenge.challengeValid = false;

        trade.isChallenged = true;
        trade.challenger = msg.sender;

        Agent storage agent = agents[trade.agent];
        agent.challengedTrades++;

        emit ChallengeSubmitted(challengeId, _tradeId, msg.sender);
        return challengeId;
    }

    // === CHALLENGE RESOLUTION ===
    function resolveChallenge(uint256 _challengeId, bool _challengeValid) external onlyOwner {
        Challenge storage challenge = challenges[_challengeId];
        require(challenge.challengeId != 0, "AgentController: challenge does not exist");
        require(!challenge.resolved, "AgentController: challenge already resolved");

        challenge.resolved = true;
        challenge.challengeValid = _challengeValid;

        Trade storage trade = trades[challenge.tradeId];
        Agent storage agent = agents[challenge.agent];

        if (_challengeValid) {
            uint256 slashAmount = (trade.bondPosted * SLASH_PERCENTAGE) / 100;
            agent.bondAmount -= slashAmount;
            agentBondBalance[challenge.agent] -= slashAmount;

            (bool success, ) = payable(msg.sender).call{value: slashAmount}("");
            require(success, "AgentController: slash transfer failed");

            trade.isResolved = true;
            emit BondSlashed(challenge.agent, slashAmount, challenge.tradeId);
        } else {
            trade.isResolved = true;
            agent.successfulTrades++;
        }

        emit ChallengeResolved(_challengeId, _challengeValid);
    }

    // === DRIFT ORACLE ===
    function updateDriftScore(address _agent, uint256 _newDriftScore) external onlyOwner {
        require(isRegisteredAgent[_agent], "AgentController: agent not registered");
        Agent storage agent = agents[_agent];
        agent.driftScore = _newDriftScore;
    }

    // === VIEW FUNCTIONS ===
    function getAgentInfo(address _agent) external view returns (
        address agentAddress,
        uint256 bondAmount,
        uint256 lastTradeTimestamp,
        uint256 totalTrades,
        uint256 successfulTrades,
        uint256 challengedTrades,
        bool isActive,
        bytes32 strategyHash,
        uint256 driftScore
    ) {
        Agent storage agent = agents[_agent];
        return (
            agent.agentAddress,
            agent.bondAmount,
            agent.lastTradeTimestamp,
            agent.totalTrades,
            agent.successfulTrades,
            agent.challengedTrades,
            agent.isActive,
            agent.strategyHash,
            agent.driftScore
        );
    }

    function getTradeInfo(uint256 _tradeId) external view returns (
        uint256 tradeId,
        address agent,
        bytes32 tradeHash,
        uint256 timestamp,
        uint256 bondPosted,
        uint256 fraudProofWindowEnd,
        bool isChallenged,
        bool isResolved,
        bytes32 challengeProof,
        address challenger
    ) {
        Trade storage trade = trades[_tradeId];
        return (
            trade.tradeId,
            trade.agent,
            trade.tradeHash,
            trade.timestamp,
            trade.bondPosted,
            trade.fraudProofWindowEnd,
            trade.isChallenged,
            trade.isResolved,
            trade.challengeProof,
            trade.challenger
        );
    }

    function getChallengeInfo(uint256 _challengeId) external view returns (
        uint256 challengeId,
        uint256 tradeId,
        address agent,
        address challenger,
        bytes32 challengeReason,
        uint256 timestamp,
        bool resolved,
        bool challengeValid
    ) {
        Challenge storage challenge = challenges[_challengeId];
        return (
            challenge.challengeId,
            challenge.tradeId,
            challenge.agent,
            challenge.challenger,
            challenge.challengeReason,
            challenge.timestamp,
            challenge.resolved,
            challenge.challengeValid
        );
    }

    function getActiveAgentsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < 1000; i++) {
            // Limited loop to prevent gas issues
            // In production, use a separate counter
        }
        return count;
    }

    function getPendingChallengesCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < 1000; i++) {
            // Limited loop to prevent gas issues
            // In production, use a separate counter
        }
        return count;
    }

    // === OWNER FUNCTIONS ===
    function setBondToken(address _bondToken) external onlyOwner {
        require(_bondToken != address(0), "AgentController: invalid token");
        bondToken = _bondToken;
    }

    function setMinBond(uint256 _minBond) external onlyOwner {
        require(_minBond > 0, "AgentController: invalid min bond");
        MIN_BOND = _minBond;
    }

    function setFraudProofWindow(uint256 _window) external onlyOwner {
        require(_window > 0, "AgentController: invalid window");
        FRAUD_PROOF_WINDOW = _window;
    }

    function deactivateAgent(address _agent) external onlyOwner {
        require(isRegisteredAgent[_agent], "AgentController: agent not registered");
        Agent storage agent = agents[_agent];
        agent.isActive = false;
    }

    function activateAgent(address _agent) external onlyOwner {
        require(isRegisteredAgent[_agent], "AgentController: agent not registered");
        Agent storage agent = agents[_agent];
        agent.isActive = true;
    }

    function withdrawOwnerFees() external onlyOwner {
        (bool success, ) = payable(owner).call{value: address(this).balance}("");
        require(success, "AgentController: withdrawal failed");
    }
}