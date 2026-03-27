// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title BondManager - Bond management for Optimistic Verification Layer
 * @notice Handles bond deposits, withdrawals, and slashing for trading agents
 * @dev Bonds are locked during fraud proof window and released if no challenge
 */
contract BondManager is ReentrancyGuard {
    using Address for address payable;

    // === STATE VARIABLES ===
    IERC20 public immutable token;
    address public owner;
    uint256 public constant MIN_BOND = 1 ether;
    uint256 public constant SLASH_PERCENTAGE = 50; // 50% slashed on fraud
    uint256 public constant FRAUD_PROOF_WINDOW = 24 hours;
    
    struct AgentBond {
        uint256 bondAmount;
        uint256 depositTimestamp;
        uint256 unlockTimestamp;
        bool isLocked;
        bool hasBeenSlashed;
    }
    
    mapping(address => AgentBond) public agentBonds;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(uint256 => address) public tradeToAgent;
    mapping(uint256 => uint256) public tradeBondAmount;
    uint256 public nextTradeId;
    
    // === EVENTS ===
    event BondDeposited(address indexed agent, uint256 amount, uint256 tradeId);
    event BondWithdrawn(address indexed agent, uint256 amount, uint256 tradeId);
    event BondSlashed(address indexed agent, uint256 amount, uint256 tradeId);
    event BondUnlocked(address indexed agent, uint256 amount, uint256 tradeId);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    // === MODIFIERS ===
    modifier onlyOwner() {
        require(msg.sender == owner, "BondManager: not owner");
        _;
    }

    modifier agentExists(address agent) {
        require(agentBonds[agent].bondAmount > 0, "BondManager: agent not registered");
        _;
    }

    // === CONSTRUCTOR ===
    constructor(address _tokenAddress) {
        require(_tokenAddress != address(0), "BondManager: invalid token address");
        token = IERC20(_tokenAddress);
        owner = msg.sender;
    }

    /**
     * @notice Deposit bond for an agent
     * @param agent The agent address
     * @param amount The bond amount to deposit
     * @param tradeId The trade ID this bond is for
     */
    function depositBond(address agent, uint256 amount, uint256 tradeId) external nonReentrant returns (bool) {
        require(amount >= MIN_BOND, "BondManager: bond too low");
        require(amount <= token.balanceOf(msg.sender), "BondManager: insufficient balance");
        
        // Transfer tokens from agent to contract
        require(token.transferFrom(msg.sender, address(this), amount), "BondManager: transfer failed");
        
        // Update agent bond state
        agentBonds[agent].bondAmount += amount;
        agentBonds[agent].depositTimestamp = block.timestamp;
        agentBonds[agent].unlockTimestamp = block.timestamp + FRAUD_PROOF_WINDOW;
        agentBonds[agent].isLocked = true;
        agentBonds[agent].hasBeenSlashed = false;
        
        // Track trade to agent mapping
        tradeToAgent[tradeId] = agent;
        tradeBondAmount[tradeId] = amount;
        
        emit BondDeposited(agent, amount, tradeId);
        return true;
    }

    /**
     * @notice Unlock bond after fraud proof window expires
     * @param agent The agent address
     * @param tradeId The trade ID to unlock
     */
    function unlockBond(address agent, uint256 tradeId) external nonReentrant returns (bool) {
        require(tradeToAgent[tradeId] == agent, "BondManager: not your trade");
        require(agentBonds[agent].isLocked, "BondManager: bond not locked");
        require(block.timestamp >= agentBonds[agent].unlockTimestamp, "BondManager: still in fraud window");
        require(!agentBonds[agent].hasBeenSlashed, "BondManager: already slashed");
        
        uint256 bondAmount = tradeBondAmount[tradeId];
        agentBonds[agent].bondAmount -= bondAmount;
        agentBonds[agent].isLocked = false;
        
        // Transfer tokens back to agent
        require(token.transfer(agent, bondAmount), "BondManager: transfer failed");
        
        emit BondUnlocked(agent, bondAmount, tradeId);
        return true;
    }

    /**
     * @notice Slash bond for fraudulent behavior
     * @param agent The agent address
     * @param tradeId The trade ID to slash
     * @param challenger The address that challenged the trade
     */
    function slashBond(address agent, uint256 tradeId, address challenger) external nonReentrant returns (bool) {
        require(tradeToAgent[tradeId] == agent, "BondManager: not your trade");
        require(agentBonds[agent].isLocked, "BondManager: bond not locked");
        require(!agentBonds[agent].hasBeenSlashed, "BondManager: already slashed");
        
        uint256 bondAmount = tradeBondAmount[tradeId];
        uint256 slashAmount = (bondAmount * SLASH_PERCENTAGE) / 100;
        uint256 refundAmount = bondAmount - slashAmount;
        
        // Slash the agent
        agentBonds[agent].bondAmount -= bondAmount;
        agentBonds[agent].hasBeenSlashed = true;
        
        // Transfer slashed amount to challenger as reward
        require(token.transfer(challenger, slashAmount), "BondManager: slash transfer failed");
        
        // Transfer refund amount back to agent
        require(token.transfer(agent, refundAmount), "BondManager: refund transfer failed");
        
        emit BondSlashed(agent, slashAmount, tradeId);
        return true;
    }

    /**
     * @notice Withdraw pending bond after fraud window
     * @param agent The agent address
     * @param amount The amount to withdraw
     */
    function withdrawBond(address agent, uint256 amount) external nonReentrant returns (bool) {
        require(agentBonds[agent].bondAmount >= amount, "BondManager: insufficient bond");
        require(!agentBonds[agent].isLocked, "BondManager: bond is locked");
        require(!agentBonds[agent].hasBeenSlashed, "BondManager: already slashed");
        
        agentBonds[agent].bondAmount -= amount;
        pendingWithdrawals[agent] += amount;
        
        emit BondWithdrawn(agent, amount, 0);
        return true;
    }

    /**
     * @notice Claim withdrawn bond
     * @param amount The amount to claim
     */
    function claimWithdrawal(uint256 amount) external nonReentrant returns (bool) {
        require(pendingWithdrawals[msg.sender] >= amount, "BondManager: no pending withdrawal");
        
        pendingWithdrawals[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "BondManager: transfer failed");
        
        return true;
    }

    /**
     * @notice Get agent bond information
     * @param agent The agent address
     * @return bondAmount The current bond amount
     * @return isLocked Whether bond is locked
     * @return unlockTimestamp When bond can be unlocked
     */
    function getAgentBond(address agent) external view returns (
        uint256 bondAmount,
        bool isLocked,
        uint256 unlockTimestamp
    ) {
        AgentBond storage bond = agentBonds[agent];
        return (bond.bondAmount, bond.isLocked, bond.unlockTimestamp);
    }

    /**
     * @notice Get pending withdrawal amount for agent
     * @param agent The agent address
     * @return amount The pending withdrawal amount
     */
    function getPendingWithdrawal(address agent) external view returns (uint256 amount) {
        return pendingWithdrawals[agent];
    }

    /**
     * @notice Get trade information
     * @param tradeId The trade ID
     * @return agent The agent address
     * @return bondAmount The bond amount
     */
    function getTradeInfo(uint256 tradeId) external view returns (
        address agent,
        uint256 bondAmount
    ) {
        return (tradeToAgent[tradeId], tradeBondAmount[tradeId]);
    }

    /**
     * @notice Get total contract balance
     * @return balance The token balance
     */
    function getContractBalance() external view returns (uint256 balance) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Emergency withdrawal for owner (only for stuck funds)
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= token.balanceOf(address(this)), "BondManager: insufficient balance");
        require(token.transfer(owner, amount), "BondManager: transfer failed");
    }

    /**
     * @notice Change contract owner
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "BondManager: invalid owner");
        owner = newOwner;
        emit OwnerChanged(msg.sender, newOwner);
    }

    /**
     * @notice Get fraud proof window duration
     * @return window The window duration in seconds
     */
    function getFraudProofWindow() external pure returns (uint256 window) {
        return FRAUD_PROOF_WINDOW;
    }
}