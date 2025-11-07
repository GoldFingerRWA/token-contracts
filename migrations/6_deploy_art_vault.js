const ARTVault = artifacts.require("ARTVault");
const ARTToken = artifacts.require("ARTToken");
const GFPriceOracle = artifacts.require("GFPriceOracle");
const GFRegistry = artifacts.require("GFRegistry");

module.exports = async function (deployer, network, accounts) {
  console.log("Deploying ARTVault...");
  console.log("Network:", network);
  console.log("Deployer account:", accounts[0]);
  
  // Get deployed contract addresses
  const artToken = await ARTToken.deployed();
  const gfPriceOracle = await GFPriceOracle.deployed();
  const gfRegistry = await GFRegistry.deployed();
  
  // Define stable coin addresses based on network
  let usdtAddress, usdcAddress;
  
  if (network === 'bsc' || network === 'bscTestnet') {
    // BSC addresses
    usdtAddress = '0x55d398326f99059fF775485246999027B3197955'; // USDT on BSC
    usdcAddress = '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d'; // USDC on BSC
  } else if (network === 'mainnet') {
    // Ethereum mainnet addresses
    usdtAddress = '0xdAC17F958D2ee523a2206206994597C13D831ec7'; // USDT on Ethereum
    usdcAddress = '0xA0b86a33E6441b5c5Cd2bd6516527d3C3ACe5e2a'; // USDC on Ethereum
  } else {
    // For development/testing, use mock addresses (you might want to deploy mock tokens)
    console.log("Warning: Using placeholder addresses for USDT/USDC in development");
    usdtAddress = '0x0000000000000000000000000000000000000001';
    usdcAddress = '0x0000000000000000000000000000000000000002';
  }
  
  console.log("Using USDT address:", usdtAddress);
  console.log("Using USDC address:", usdcAddress);
  console.log("Using ARTToken address:", artToken.address);
  console.log("Using GFPriceOracle address:", gfPriceOracle.address);
  console.log("Using GFRegistry address:", gfRegistry.address);
  
  // Deploy ARTVault
  await deployer.deploy(
    ARTVault,
    artToken.address,
    usdtAddress,
    usdcAddress,
    gfPriceOracle.address,
    gfRegistry.address
  );
  
  const artVault = await ARTVault.deployed();
  
  console.log("ARTVault deployed at:", artVault.address);
  
  // Set environment variable for other migrations
  process.env.ART_VAULT_ADDRESS = artVault.address;
};