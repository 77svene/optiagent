const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("=== OptiAgent Deployment to Sepolia ===\n");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Deploy BondManager first (dependency for other contracts)
  console.log("\n1. Deploying BondManager...");
  const BondManager = await hre.ethers.getContractFactory("BondManager");
  const bondManager = await BondManager.deploy(deployer.address);
  await bondManager.waitForDeployment();
  const bondManagerAddress = await bondManager.getAddress();
  console.log("BondManager deployed at:", bondManagerAddress);

  // Deploy FraudProofWindow
  console.log("\n2. Deploying FraudProofWindow...");
  const FraudProofWindow = await hre.ethers.getContractFactory("FraudProofWindow");
  const fraudProofWindow = await FraudProofWindow.deploy(
    bondManagerAddress,
    86400 // 24-hour fraud proof window in seconds
  );
  await fraudProofWindow.waitForDeployment();
  const fraudProofWindowAddress = await fraudProofWindow.getAddress();
  console.log("FraudProofWindow deployed at:", fraudProofWindowAddress);

  // Deploy DriftOracle
  console.log("\n3. Deploying DriftOracle...");
  const DriftOracle = await hre.ethers.getContractFactory("DriftOracle");
  const driftOracle = await DriftOracle.deploy(
    bondManagerAddress,
    fraudProofWindowAddress
  );
  await driftOracle.waitForDeployment();
  const driftOracleAddress = await driftOracle.getAddress();
  console.log("DriftOracle deployed at:", driftOracleAddress);

  // Deploy ChallengeVerifier
  console.log("\n4. Deploying ChallengeVerifier...");
  const ChallengeVerifier = await hre.ethers.getContractFactory("ChallengeVerifier");
  const challengeVerifier = await ChallengeVerifier.deploy(
    bondManagerAddress,
    fraudProofWindowAddress,
    driftOracleAddress
  );
  await challengeVerifier.waitForDeployment();
  const challengeVerifierAddress = await challengeVerifier.getAddress();
  console.log("ChallengeVerifier deployed at:", challengeVerifierAddress);

  // Deploy AgentController
  console.log("\n5. Deploying AgentController...");
  const AgentController = await hre.ethers.getContractFactory("AgentController");
  const agentController = await AgentController.deploy(
    bondManagerAddress,
    fraudProofWindowAddress,
    driftOracleAddress,
    challengeVerifierAddress
  );
  await agentController.waitForDeployment();
  const agentControllerAddress = await agentController.getAddress();
  console.log("AgentController deployed at:", agentControllerAddress);

  // Save deployment addresses
  const deploymentData = {
    network: hre.network.name,
    chainId: await hre.ethers.provider.getNetwork().then(n => n.chainId),
    deployer: deployer.address,
    timestamp: Math.floor(Date.now() / 1000),
    contracts: {
      BondManager: bondManagerAddress,
      FraudProofWindow: fraudProofWindowAddress,
      DriftOracle: driftOracleAddress,
      ChallengeVerifier: challengeVerifierAddress,
      AgentController: agentControllerAddress,
    }
  };

  const deploymentPath = path.join(__dirname, "..", "deployment.json");
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentData, null, 2));
  console.log("\nDeployment data saved to:", deploymentPath);

  // Verify contracts on Etherscan if Sepolia
  if (hre.network.name === "sepolia") {
    console.log("\n6. Verifying contracts on Etherscan...");
    try {
      await hre.run("verify:verify", {
        address: bondManagerAddress,
      });
      console.log("BondManager verified");
    } catch (e) {
      console.log("BondManager verification skipped or failed:", e.message);
    }
  }

  console.log("\n=== Deployment Complete ===");
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", deploymentData.chainId);
  console.log("\nContract Addresses:");
  for (const [name, address] of Object.entries(deploymentData.contracts)) {
    console.log(`  ${name}: ${address}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });