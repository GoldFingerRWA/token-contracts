#!/usr/bin/env node

/**
 * Script to get the implementation address from a proxy contract
 * Based on BUSD contract repository pattern
 */

const Web3 = require('web3');

module.exports = async function(callback) {
  try {
    const web3 = new Web3(process.env.WEB3_PROVIDER_URL || 'https://bsc-dataseed1.binance.org');
    
    // Proxy contract address (update with actual proxy address)
    const proxyAddress = process.argv[4] || process.env.PROXY_ADDRESS;
    
    if (!proxyAddress) {
      console.log('Please provide proxy address as argument or set PROXY_ADDRESS environment variable');
      callback();
      return;
    }
    
    console.log('Getting implementation address for proxy:', proxyAddress);
    
    // EIP-1967 standard storage slot for implementation
    const implementationSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
    
    // Get storage at the implementation slot
    const implementationAddress = await web3.eth.getStorageAt(proxyAddress, implementationSlot);
    
    // Clean up the address (remove leading zeros and add 0x prefix)
    const cleanAddress = '0x' + implementationAddress.slice(-40);
    
    console.log('Implementation address:', cleanAddress);
    
    callback();
  } catch (error) {
    console.error('Error getting implementation address:', error);
    callback(error);
  }
};