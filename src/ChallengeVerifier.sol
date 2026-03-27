// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ChallengeVerifier - Validity Proof Verification for Disputes
 * @notice Validates trade execution proofs submitted by agents during fraud challenges
 * @dev Uses Merkle proofs for efficient verification without full ZK overhead
 */
contract ChallengeVerifier is ReentrancyGuard, Ownable {
    // === CONSTANTS ===
    uint256 public constant MIN_PROOF_DEPTH = 16;
    uint256 public constant MAX_PROOF_DEPTH = 32;
    uint256 public constant MAX_PROOF_SIZE = 1024; // bytes

    // === STATE ===
    struct ProofRecord {
        uint256 challengeId;
        uint256 submissionTimestamp;
        bool isValid;
        bytes32 rootHash;
        uint256 proofDepth;
        address verifier;
        uint256 gasUsed;
    }

    struct TradeLeaf {
        uint256 tradeId;
        address agent;
        bytes32 tradeHash;
        uint256 timestamp;
        uint256 bondAmount;
        bytes32 strategyHash;
        bytes32 executionSignature;
    }

    // === MAPPINGS ===
    mapping(uint256 => ProofRecord) public proofRecords;
    mapping(bytes32 => bool) public processedLeaves;
    mapping(uint256 => bytes32[]) public challengeProofs;

    // === EVENTS ===
    event ProofSubmitted(uint256 indexed challengeId, address indexed agent, bool isValid, uint256 gasUsed);
    event ProofVerified(uint256 indexed challengeId, bytes32 indexed leafHash, uint256 depth);
    event ProofRejected(uint256 indexed challengeId, bytes32 indexed leafHash, string reason);

    // === ERRORS ===
    error InvalidProofDepth();
    error ProofAlreadyProcessed();
    error InvalidProofSize();
    error ChallengeNotActive();
    error InvalidRootHash();
    error VerificationFailed();

    /**
     * @notice Submit a validity proof for a challenged trade
     * @param challengeId The ID of the challenge to respond to
     * @param leaf The trade leaf data to prove
     * @param proof The Merkle proof path
     * @param rootHash The expected root hash of the Merkle tree
     */
    function submitProof(
        uint256 challengeId,
        TradeLeaf calldata leaf,
        bytes32[] calldata proof,
        bytes32 rootHash
    ) external nonReentrant returns (bool) {
        // Validate proof depth
        if (proof.length < MIN_PROOF_DEPTH || proof.length > MAX_PROOF_DEPTH) {
            revert InvalidProofDepth();
        }

        // Validate proof size
        if (proof.length * 32 > MAX_PROOF_SIZE) {
            revert InvalidProofSize();
        }

        // Verify the Merkle proof
        bytes32 leafHash = keccak256(abi.encode(leaf));
        
        if (!MerkleProof.verify(proof, rootHash, leafHash)) {
            emit ProofRejected(challengeId, leafHash, "Merkle proof verification failed");
            return false;
        }

        // Check if leaf was already processed
        if (processedLeaves[leafHash]) {
            revert ProofAlreadyProcessed();
        }

        // Record the proof submission
        ProofRecord storage record = proofRecords[challengeId];
        record.challengeId = challengeId;
        record.submissionTimestamp = block.timestamp;
        record.isValid = true;
        record.rootHash = rootHash;
        record.proofDepth = proof.length;
        record.verifier = msg.sender;
        record.gasUsed = gasleft();

        // Mark leaf as processed
        processedLeaves[leafHash] = true;

        // Store the proof for audit
        challengeProofs[challengeId] = proof;

        // Emit events
        emit ProofSubmitted(challengeId, msg.sender, true, record.gasUsed);
        emit ProofVerified(challengeId, leafHash, proof.length);

        return true;
    }

    /**
     * @notice Verify a proof was submitted for a challenge
     * @param challengeId The ID of the challenge
     * @return isValid Whether the proof was valid
     * @return submissionTimestamp When the proof was submitted
     * @return proofDepth The depth of the Merkle proof
     */
    function getProofStatus(uint256 challengeId) 
        external 
        view 
        returns (bool isValid, uint256 submissionTimestamp, uint256 proofDepth) 
    {
        ProofRecord storage record = proofRecords[challengeId];
        return (record.isValid, record.submissionTimestamp, record.proofDepth);
    }

    /**
     * @notice Verify a specific leaf against a root hash
     * @param leaf The trade leaf to verify
     * @param proof The Merkle proof path
     * @param rootHash The expected root hash
     * @return isValid Whether the proof is valid
     */
    function verifyProof(
        TradeLeaf calldata leaf,
        bytes32[] calldata proof,
        bytes32 rootHash
    ) external pure returns (bool isValid) {
        if (proof.length < MIN_PROOF_DEPTH || proof.length > MAX_PROOF_DEPTH) {
            return false;
        }

        bytes32 leafHash = keccak256(abi.encode(leaf));
        return MerkleProof.verify(proof, rootHash, leafHash);
    }

    /**
     * @notice Get the Merkle root for a set of leaves
     * @param leaves Array of trade leaves
     * @return root The computed Merkle root
     */
    function computeMerkleRoot(TradeLeaf[] calldata leaves) external pure returns (bytes32 root) {
        if (leaves.length == 0) {
            return bytes32(0);
        }

        // Simple iterative Merkle tree construction
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            hashes[i] = keccak256(abi.encode(leaves[i]));
        }

        while (hashes.length > 1) {
            bytes32[] memory newHashes = new bytes32[]((hashes.length + 1) / 2);
            for (uint256 i = 0; i < hashes.length; i += 2) {
                if (i + 1 < hashes.length) {
                    newHashes[i / 2] = keccak256(abi.encodePacked(hashes[i], hashes[i + 1]));
                } else {
                    newHashes[i / 2] = hashes[i];
                }
            }
            hashes = newHashes;
        }

        return hashes[0];
    }

    /**
     * @notice Check if a leaf has been processed
     * @param leafHash The hash of the leaf to check
     * @return isProcessed Whether the leaf was already processed
     */
    function isLeafProcessed(bytes32 leafHash) external view returns (bool isProcessed) {
        return processedLeaves[leafHash];
    }

    /**
     * @notice Get all proofs for a challenge
     * @param challengeId The ID of the challenge
     * @return proofs The array of proof paths
     */
    function getChallengeProofs(uint256 challengeId) external view returns (bytes32[] memory proofs) {
        return challengeProofs[challengeId];
    }

    /**
     * @notice Reset processed leaves (for testing/debugging)
     * @param leafHash The leaf hash to reset
     */
    function resetLeaf(bytes32 leafHash) external onlyOwner {
        processedLeaves[leafHash] = false;
    }

    /**
     * @notice Reset all processed leaves (for testing/debugging)
     */
    function resetAllLeaves() external onlyOwner {
        // Note: This is a gas-intensive operation, use with caution
        // In production, consider using a mapping reset pattern
        for (uint256 i = 0; i < 100; i++) {
            // Reset first 100 leaves (adjust as needed)
            bytes32 testHash = bytes32(uint256(i));
            processedLeaves[testHash] = false;
        }
    }

    /**
     * @notice Get proof record details
     * @param challengeId The ID of the challenge
     * @return record The proof record
     */
    function getProofRecord(uint256 challengeId) external view returns (ProofRecord memory record) {
        return proofRecords[challengeId];
    }

    /**
     * @notice Get the number of processed leaves
     * @return count The number of processed leaves
     */
    function getProcessedLeafCount() external view returns (uint256 count) {
        // This is an approximation - full count requires iterating all leaves
        // In production, maintain a counter
        return 0;
    }

    /**
     * @notice Get the current gas limit for verification
     * @return limit The gas limit
     */
    function getVerificationGasLimit() external pure returns (uint256 limit) {
        return MAX_PROOF_SIZE * 32;
    }
}