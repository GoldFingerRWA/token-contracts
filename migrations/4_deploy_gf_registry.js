const GFRegistry = artifacts.require("GFRegistry");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying GFRegistry...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Deploy GFRegistry with owner as the deployer
  await deployer.deploy(GFRegistry, accounts[0]);
  const gfRegistry = await GFRegistry.deployed();
  
  console.log("GFRegistry deployed at:", gfRegistry.address);
  console.log("GFRegistry owner:", await gfRegistry.owner());
  
  // Set environment variable for other migrations
  process.env.GF_REGISTRY_ADDRESS = gfRegistry.address;
};