const GFPriceOracle = artifacts.require("GFPriceOracle");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying GFPriceOracle...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Deploy GFPriceOracle with owner as the deployer
  await deployer.deploy(GFPriceOracle, accounts[0]);
  const gfPriceOracle = await GFPriceOracle.deployed();
  
  console.log("GFPriceOracle deployed at:", gfPriceOracle.address);
  console.log("GFPriceOracle owner:", await gfPriceOracle.owner());
  
  // Set environment variable for other migrations
  process.env.GF_PRICE_ORACLE_ADDRESS = gfPriceOracle.address;
};