const GFToken = artifacts.require("GFToken");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying GFToken...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Deploy GFToken with owner as the deployer
  await deployer.deploy(GFToken, accounts[0]);
  const gfToken = await GFToken.deployed();
  
  console.log("GFToken deployed at:", gfToken.address);
  console.log("GFToken owner:", await gfToken.owner());
  console.log("GFToken total supply:", (await gfToken.totalSupply()).toString());
  
  // Set environment variable for other migrations
  process.env.GF_TOKEN_ADDRESS = gfToken.address;
};