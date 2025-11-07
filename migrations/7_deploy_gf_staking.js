const GFStaking = artifacts.require("GFStaking");
const GFToken = artifacts.require("GFToken");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying GFStaking...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Get deployed GFToken address
  const gfToken = await GFToken.deployed();
  
  console.log("Using GFToken address:", gfToken.address);
  
  // Deploy GFStaking with GFToken address
  await deployer.deploy(GFStaking, gfToken.address);
  const gfStaking = await GFStaking.deployed();
  
  console.log("GFStaking deployed at:", gfStaking.address);
  
  // Set environment variable for other migrations
  process.env.GF_STAKING_ADDRESS = gfStaking.address;
};