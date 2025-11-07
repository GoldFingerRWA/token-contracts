const ARTToken = artifacts.require("ARTToken");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying ARTToken...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Deploy ARTToken with owner as the deployer
  await deployer.deploy(ARTToken, accounts[0]);
  const artToken = await ARTToken.deployed();
  
  console.log("ARTToken deployed at:", artToken.address);
  console.log("ARTToken owner:", await artToken.owner());
  console.log("ARTToken total supply:", (await artToken.totalSupply()).toString());
  
  // Set environment variable for other migrations
  process.env.ART_TOKEN_ADDRESS = artToken.address;
};