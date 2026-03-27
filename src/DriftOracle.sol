// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DriftOracle - Performance Monitoring and Drift Detection
 * @notice Tracks agent performance metrics and triggers challenges on anomalous behavior
 * @dev Calculates drift score based on PnL deviation, execution time, and trade success rate
 */
contract DriftOracle is ReentrancyGuard, Ownable {
    using Address for address;
    using ECDSA for bytes32;

    // === CONSTANTS ===
    uint256 public constant DRIFT_THRESHOLD = 75; // Percentage threshold for auto-challenge
    uint256 public constant MIN_DATA_POINTS = 5; // Minimum trades before drift calculation
    uint256 public constant MAX_HISTORY = 100; // Maximum trade history per agent
    uint256 public constant PNL_WEIGHT = 40; // Weight for PnL deviation
    uint256 public constant EXEC_TIME_WEIGHT = 30; // Weight for execution time deviation
    uint256 public constant SUCCESS_RATE_WEIGHT = 30; // Weight for success rate deviation

    // === STATE ===
    struct AgentMetrics {
        uint256 totalPnL;
        uint256 totalTrades;
        uint256 successfulTrades;
        uint256 totalExecutionTime;
        uint256 lastDriftScore;
        uint256 lastDriftTimestamp;
        bool isMonitored;
    }

    struct TradeRecord {
        uint256 tradeId;
        uint256 timestamp;
        int256 pnl;
        uint256 executionTime;
        bool isSuccessful;
    }

    struct DriftHistory {
        uint256 timestamp;
        uint256 driftScore;
        bool triggeredChallenge;
    }

    mapping(address => AgentMetrics) public agentMetrics;
    mapping(address => TradeRecord[]) public agentTradeHistory;
    mapping(address => DriftHistory[]) public agentDriftHistory;
    mapping(address => bool) public isRegisteredAgent;
    address public agentController;

    // === EVENTS ===
    event AgentRegistered(address indexed agent, uint256 timestamp);
    event TradeRecorded(address indexed agent, uint256 tradeId, int256 pnl, uint256 executionTime);
    event DriftScoreCalculated(address indexed agent, uint256 driftScore, uint256 timestamp);
    event ChallengeTriggered(address indexed agent, uint256 driftScore, uint256 timestamp);
    event MetricsUpdated(address indexed agent, uint256 newDriftScore);

    // === ERRORS ===
    error AgentNotRegistered();
    error InsufficientDataPoints();
    error DriftBelowThreshold();
    error InvalidAgentAddress();

    // === MODIFIERS ===
    modifier onlyAgentController() {
        require(msg.sender == agentController, "DriftOracle: not agent controller");
        _;
    }

    modifier onlyRegisteredAgent() {
        require(isRegisteredAgent[msg.sender], "DriftOracle: agent not registered");
        _;
    }

    // === CONSTRUCTOR ===
    constructor(address _agentController) Ownable(msg.sender) {
        if (_agentController != address(0)) {
            agentController = _agentController;
        }
    }

    // === PUBLIC FUNCTIONS ===
    function setAgentController(address _agentController) external onlyOwner {
        require(_agentController != address(0), "DriftOracle: invalid address");
        agentController = _agentController;
    }

    function registerAgent(address agent) external onlyOwner {
        require(agent != address(0), "DriftOracle: invalid agent address");
        require(!isRegisteredAgent[agent], "DriftOracle: agent already registered");

        isRegisteredAgent[agent] = true;
        agentMetrics[agent].isMonitored = true;

        emit AgentRegistered(agent, block.timestamp);
    }

    function recordTrade(
        address agent,
        uint256 tradeId,
        int256 pnl,
        uint256 executionTime,
        bool isSuccessful
    ) external onlyAgentController {
        require(isRegisteredAgent[agent], "DriftOracle: agent not registered");

        AgentMetrics storage metrics = agentMetrics[agent];
        TradeRecord[] storage history = agentTradeHistory[agent];

        // Update metrics
        metrics.totalTrades += 1;
        metrics.totalExecutionTime += executionTime;
        if (pnl > 0) {
            metrics.totalPnL += uint256(pnl);
        }
        if (isSuccessful) {
            metrics.successfulTrades += 1;
        }

        // Record trade
        if (history.length >= MAX_HISTORY) {
            // Remove oldest record to maintain max size
            for (uint256 i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history.pop();
        }

        history.push(TradeRecord({
            tradeId: tradeId,
            timestamp: block.timestamp,
            pnl: pnl,
            executionTime: executionTime,
            isSuccessful: isSuccessful
        }));

        emit TradeRecorded(agent, tradeId, pnl, executionTime);

        // Calculate drift score after minimum data points
        if (metrics.totalTrades >= MIN_DATA_POINTS) {
            uint256 driftScore = calculateDriftScore(agent);
            metrics.lastDriftScore = driftScore;
            metrics.lastDriftTimestamp = block.timestamp;

            emit DriftScoreCalculated(agent, driftScore, block.timestamp);

            // Trigger challenge if drift exceeds threshold
            if (driftScore >= DRIFT_THRESHOLD) {
                emit ChallengeTriggered(agent, driftScore, block.timestamp);
            }
        }
    }

    function calculateDriftScore(address agent) public view returns (uint256) {
        require(isRegisteredAgent[agent], "DriftOracle: agent not registered");

        AgentMetrics storage metrics = agentMetrics[agent];
        TradeRecord[] storage history = agentTradeHistory[agent];

        require(history.length >= MIN_DATA_POINTS, "DriftOracle: insufficient data points");

        // Calculate PnL deviation (0-100 scale)
        uint256 pnlDeviation = _calculatePnLDeviation(agent, metrics, history);

        // Calculate execution time deviation (0-100 scale)
        uint256 execTimeDeviation = _calculateExecutionTimeDeviation(agent, metrics, history);

        // Calculate success rate deviation (0-100 scale)
        uint256 successRateDeviation = _calculateSuccessRateDeviation(agent, metrics, history);

        // Weighted average
        uint256 driftScore = (
            (pnlDeviation * PNL_WEIGHT) +
            (execTimeDeviation * EXEC_TIME_WEIGHT) +
            (successRateDeviation * SUCCESS_RATE_WEIGHT)
        ) / 100;

        return driftScore;
    }

    function getAgentMetrics(address agent) external view returns (
        uint256 totalPnL,
        uint256 totalTrades,
        uint256 successfulTrades,
        uint256 totalExecutionTime,
        uint256 lastDriftScore,
        uint256 lastDriftTimestamp,
        bool isMonitored
    ) {
        require(isRegisteredAgent[agent], "DriftOracle: agent not registered");

        AgentMetrics storage metrics = agentMetrics[agent];
        return (
            metrics.totalPnL,
            metrics.totalTrades,
            metrics.successfulTrades,
            metrics.totalExecutionTime,
            metrics.lastDriftScore,
            metrics.lastDriftTimestamp,
            metrics.isMonitored
        );
    }

    function getDriftHistory(address agent, uint256 startIndex, uint256 count) external view returns (DriftHistory[] memory) {
        require(isRegisteredAgent[agent], "DriftOracle: agent not registered");
        require(startIndex + count <= agentDriftHistory[agent].length, "DriftOracle: out of bounds");

        DriftHistory[] storage history = agentDriftHistory[agent];
        DriftHistory[] memory result = new DriftHistory[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = history[startIndex + i];
        }

        return result;
    }

    function getTradeHistory(address agent, uint256 startIndex, uint256 count) external view returns (TradeRecord[] memory) {
        require(isRegisteredAgent[agent], "DriftOracle: agent not registered");
        require(startIndex + count <= agentTradeHistory[agent].length, "DriftOracle: out of bounds");

        TradeRecord[] storage history = agentTradeHistory[agent];
        TradeRecord[] memory result = new TradeRecord[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = history[startIndex + i];
        }

        return result;
    }

    function isAgentMonitored(address agent) external view returns (bool) {
        return isRegisteredAgent[agent] && agentMetrics[agent].isMonitored;
    }

    // === INTERNAL FUNCTIONS ===
    function _calculatePnLDeviation(address agent, AgentMetrics storage metrics, TradeRecord[] storage history) internal view returns (uint256) {
        if (history.length == 0) return 0;

        // Calculate average PnL
        int256 totalPnL = 0;
        for (uint256 i = 0; i < history.length; i++) {
            totalPnL += history[i].pnl;
        }

        int256 avgPnL = totalPnL / int256(history.length);

        // Calculate deviation from expected (assume 0 is expected, positive is good)
        // Higher deviation = higher drift score
        uint256 deviation = 0;
        if (avgPnL > 0) {
            deviation = uint256(avgPnL) / 100; // Scale down to 0-100 range
        } else {
            deviation = uint256(-avgPnL) / 100;
        }

        // Cap at 100
        if (deviation > 100) deviation = 100;

        return deviation;
    }

    function _calculateExecutionTimeDeviation(address agent, AgentMetrics storage metrics, TradeRecord[] storage history) internal view returns (uint256) {
        if (history.length == 0) return 0;

        // Calculate average execution time
        uint256 totalExecTime = 0;
        for (uint256 i = 0; i < history.length; i++) {
            totalExecTime += history[i].executionTime;
        }

        uint256 avgExecTime = totalExecTime / history.length;

        // Assume 100ms is normal, higher is deviation
        uint256 deviation = 0;
        if (avgExecTime > 100) {
            deviation = (avgExecTime - 100) / 10; // Scale to 0-100
        }

        // Cap at 100
        if (deviation > 100) deviation = 100;

        return deviation;
    }

    function _calculateSuccessRateDeviation(address agent, AgentMetrics storage metrics, TradeRecord[] storage history) internal view returns (uint256) {
        if (history.length == 0) return 0;

        // Calculate success rate
        uint256 successRate = (metrics.successfulTrades * 100) / metrics.totalTrades;

        // Assume 90% success rate is expected
        uint256 deviation = 0;
        if (successRate < 90) {
            deviation = (90 - successRate) * 10; // Scale to 0-100
        }

        // Cap at 100
        if (deviation > 100) deviation = 100;

        return deviation;
    }

    function _recordDriftHistory(address agent, uint256 driftScore) internal {
        DriftHistory[] storage history = agentDriftHistory[agent];

        DriftHistory memory record = DriftHistory({
            timestamp: block.timestamp,
            driftScore: driftScore,
            triggeredChallenge: driftScore >= DRIFT_THRESHOLD
        });

        if (history.length >= MAX_HISTORY) {
            for (uint256 i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history.pop();
        }

        history.push(record);
    }
}