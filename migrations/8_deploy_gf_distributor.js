const GFDistributor = artifacts.require("GFDistributor");
const GFToken = artifacts.require("GFToken");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying GFDistributor...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Get deployed GFToken address
  const gfToken = await GFToken.deployed();
  
  console.log("Using GFToken address:", gfToken.address);
  
  // Deploy GFDistributor with GFToken address
  await deployer.deploy(GFDistributor, gfToken.address);
  const gfDistributor = await GFDistributor.deployed();
  
  console.log("GFDistributor deployed at:", gfDistributor.address);
  
  // Set environment variable for other migrations
  process.env.GF_DISTRIBUTOR_ADDRESS = gfDistributor.address;
};