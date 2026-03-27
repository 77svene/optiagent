// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title FraudProofWindow - Optimistic Verification Challenge System
 * @notice Allows any address to challenge trades within 24-hour window
 * @dev Bond slashing for agents if challenge proves invalid behavior
 */
contract FraudProofWindow is ReentrancyGuard {
    using Address for address;
    using ECDSA for bytes32;

    // === CONSTANTS ===
    uint256 public constant FRAUD_PROOF_WINDOW = 24 hours;
    uint256 public constant CHALLENGE_BOND = 0.1 ether;
    uint256 public constant SLASH_PERCENTAGE = 100;

    // === STATE ===
    struct Challenge {
        uint256 challengeId;
        uint256 tradeId;
        address challenger;
        address agent;
        uint256 timestamp;
        bytes32 challengeProof;
        bool isValid;
        bool isResolved;
        uint256 resolutionTimestamp;
    }

    struct TradeChallenge {
        bool isChallenged;
        uint256 challengeCount;
        mapping(uint256 => Challenge) challenges;
    }

    // === MAPPINGS ===
    mapping(uint256 => TradeChallenge) public tradeChallenges;
    mapping(address => uint256) public agentChallenges;
    mapping(address => uint256) public agentSlashBalance;
    mapping(address => uint256) public agentBond;
    mapping(address => bool) public registeredAgents;
    mapping(uint256 => Challenge) public challenges;
    uint256 public challengeCounter;
    uint256 public tradeCounter;

    // === EVENTS ===
    event ChallengeSubmitted(uint256 indexed challengeId, uint256 indexed tradeId, address indexed challenger, uint256 bondPosted);
    event ChallengeResolved(uint256 indexed challengeId, bool isValid, address agent, uint256 slashAmount);
    event AgentBondPosted(address indexed agent, uint256 amount);
    event AgentBondSlashed(address indexed agent, uint256 amount);

    // === CONSTRUCTOR ===
    constructor() {
        challengeCounter = 0;
        tradeCounter = 0;
    }

    /**
     * @notice Register an agent to participate in the system
     * @param agentAddress The agent's address
     * @param initialBond The initial bond amount to post
     */
    function registerAgent(address agentAddress, uint256 initialBond) external {
        require(!registeredAgents[agentAddress], "Agent already registered");
        require(initialBond > 0, "Bond must be positive");
        
        registeredAgents[agentAddress] = true;
        agentBond[agentAddress] = initialBond;
        
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), initialBond);
        
        emit AgentBondPosted(agentAddress, initialBond);
    }

    /**
     * @notice Submit a challenge against a trade
     * @param tradeId The trade to challenge
     * @param challengeProof The proof of invalid behavior
     */
    function submitChallenge(uint256 tradeId, bytes32 challengeProof) external nonReentrant {
        require(registeredAgents[tradeChallenges[tradeId].challenges[0].agent], "Trade not from registered agent");
        
        uint256 tradeTimestamp = tradeChallenges[tradeId].challenges[0].timestamp;
        require(block.timestamp <= tradeTimestamp + FRAUD_PROOF_WINDOW, "Fraud proof window expired");
        
        uint256 challengeId = challengeCounter;
        challengeCounter++;
        
        address agent = tradeChallenges[tradeId].challenges[0].agent;
        
        Challenge memory newChallenge = Challenge({
            challengeId: challengeId,
            tradeId: tradeId,
            challenger: msg.sender,
            agent: agent,
            timestamp: block.timestamp,
            challengeProof: challengeProof,
            isValid: false,
            isResolved: false,
            resolutionTimestamp: 0
        });
        
        challenges[challengeId] = newChallenge;
        tradeChallenges[tradeId].challenges[challengeId] = newChallenge;
        tradeChallenges[tradeId].isChallenged = true;
        tradeChallenges[tradeId].challengeCount++;
        agentChallenges[agent]++;
        
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), CHALLENGE_BOND);
        
        emit ChallengeSubmitted(challengeId, tradeId, msg.sender, CHALLENGE_BOND);
    }

    /**
     * @notice Resolve a challenge as valid (agent loses bond)
     * @param challengeId The challenge to resolve
     */
    function resolveChallengeValid(uint256 challengeId) external nonReentrant {
        Challenge storage challenge = challenges[challengeId];
        require(!challenge.isResolved, "Challenge already resolved");
        require(challenge.challenger == msg.sender || isAuthorizedResolver(msg.sender), "Unauthorized");
        
        challenge.isValid = true;
        challenge.isResolved = true;
        challenge.resolutionTimestamp = block.timestamp;
        
        address agent = challenge.agent;
        uint256 slashAmount = agentBond[agent] * SLASH_PERCENTAGE / 100;
        
        agentBond[agent] = agentBond[agent] - slashAmount;
        agentSlashBalance[agent] = agentSlashBalance[agent] + slashAmount;
        
        IERC20(tokenAddress).transfer(msg.sender, slashAmount);
        
        emit ChallengeResolved(challengeId, true, agent, slashAmount);
        emit AgentBondSlashed(agent, slashAmount);
    }

    /**
     * @notice Resolve a challenge as invalid (challenger loses bond)
     * @param challengeId The challenge to resolve
     */
    function resolveChallengeInvalid(uint256 challengeId) external nonReentrant {
        Challenge storage challenge = challenges[challengeId];
        require(!challenge.isResolved, "Challenge already resolved");
        require(challenge.challenger == msg.sender || isAuthorizedResolver(msg.sender), "Unauthorized");
        
        challenge.isValid = false;
        challenge.isResolved = true;
        challenge.resolutionTimestamp = block.timestamp;
        
        address agent = challenge.agent;
        uint256 refundAmount = CHALLENGE_BOND;
        
        IERC20(tokenAddress).transfer(agent, refundAmount);
        
        emit ChallengeResolved(challengeId, false, agent, 0);
    }

    /**
     * @notice Get challenge details
     * @param challengeId The challenge ID
     * @return challenge The challenge struct
     */
    function getChallenge(uint256 challengeId) external view returns (Challenge memory challenge) {
        return challenges[challengeId];
    }

    /**
     * @notice Get trade challenge status
     * @param tradeId The trade ID
     * @return isChallenged Whether trade is challenged
     * @return challengeCount Number of challenges
     */
    function getTradeChallengeStatus(uint256 tradeId) external view returns (bool isChallenged, uint256 challengeCount) {
        TradeChallenge storage tc = tradeChallenges[tradeId];
        return (tc.isChallenged, tc.challengeCount);
    }

    /**
     * @notice Get agent's bond balance
     * @param agent The agent address
     * @return bondAmount The bond amount
     */
    function getAgentBond(address agent) external view returns (uint256 bondAmount) {
        return agentBond[agent];
    }

    /**
     * @notice Get agent's total slashed amount
     * @param agent The agent address
     * @return slashAmount The total slashed amount
     */
    function getAgentSlashBalance(address agent) external view returns (uint256 slashAmount) {
        return agentSlashBalance[agent];
    }

    /**
     * @notice Check if agent is registered
     * @param agent The agent address
     * @return isRegistered Whether agent is registered
     */
    function isAgentRegistered(address agent) external view returns (bool isRegistered) {
        return registeredAgents[agent];
    }

    /**
     * @notice Get fraud proof window end time for a trade
     * @param tradeId The trade ID
     * @return windowEnd The timestamp when window expires
     */
    function getFraudProofWindowEnd(uint256 tradeId) external view returns (uint256 windowEnd) {
        uint256 tradeTimestamp = tradeChallenges[tradeId].challenges[0].timestamp;
        return tradeTimestamp + FRAUD_PROOF_WINDOW;
    }

    /**
     * @notice Check if address is authorized resolver
     * @param addr The address to check
     * @return isAuthorized Whether address is authorized
     */
    function isAuthorizedResolver(address addr) public view returns (bool isAuthorized) {
        return addr == owner;
    }

    // === TOKEN ADDRESS ===
    address public tokenAddress;
    address public owner;

    /**
     * @notice Set the token address for bond management
     * @param _tokenAddress The token address
     */
    function setTokenAddress(address _tokenAddress) external {
        require(msg.sender == owner, "Not owner");
        tokenAddress = _tokenAddress;
    }

    /**
     * @notice Set owner
     * @param _owner The new owner address
     */
    function setOwner(address _owner) external {
        require(msg.sender == owner, "Not owner");
        owner = _owner;
    }
}