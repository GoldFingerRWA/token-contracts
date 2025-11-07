# 部署合约 - BNB Smart Chain Testnet (97) network
## 0. 部署参数
- Use remix (https://remix.ethereum.org/)
    - Plugin Manager: Activate CONTRACT VERIFICATION
        - Settings:
            - etherscan.io API Key: 8U53EJCFBRCZ5H7QF2ZAJXURWHY74EUZZY
- Compiling
    - Compiler: 0.8.30
    - Language: Solidity
	- EVM version: default (prague)
	- Optimization: 200

- CONTRACT VERIFICATION
    - Chain: 
      - BNB Smart Chain (56)
      - Ethernet Chain (1)
	- Vefify on: Etherscan

## 0. USDC
- Mainnet
	- https://www.usdc.com/
	- EIP-1967 Transparent Proxy
	- Proxy: https://bscscan.com/token/0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d

## 0. USDT
- Mainnet
	- https://tether.to/en/
	- Ref: https://bscscan.com/token/0x55d398326f99059fF775485246999027B3197955

### 1. ARTToken
- https://bscscan.com/address/0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424

### 2. GFToken
- https://bscscan.com/address/0xBAD7118C5b445D44Dee72E186D594D315ac7792b

### 3. GFPriceOracle
- https://bscscan.com/address/0x2c1Bd629A23322BD54D403C9139743795903b4F4

### 4. GFRegistry
- https://bscscan.com/address/0xD1aB3Ba1882E7F2A1DE63849048Ed20a97F17A9a

### 5. ARTVault
- Deploy
	- artToken:0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424
	- usdt:0x55d398326f99059fF775485246999027B3197955
	- usdc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d
	- priceOracle:0x2c1Bd629A23322BD54D403C9139743795903b4F4
	- registry:0xD1aB3Ba1882E7F2A1DE63849048Ed20a97F17A9a
- https://bscscan.com/address/0xAa8cD8244843BF3e34dc5A978C29854f6C234643

### 6. GFDistributor
- Deploy
	- gfToken:0xBAD7118C5b445D44Dee72E186D594D315ac7792b
- https://bscscan.com/address/0xCEE77C30Cce9BbCD35c0E2B05a414D4941d8572B

### 7. GFStaking
- Deploy
	- artToken:0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424
	- gfToken:0xBAD7118C5b445D44Dee72E186D594D315ac7792b
- https://bscscan.com/address/0x96e4519B0c0CFc3edAc80Bcef5C5D0361B1A77F8

### 8. Setup
- ARTToken:　https://bscscan.com/address/0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424
	- setVault: 0xAa8cD8244843BF3e34dc5A978C29854f6C234643
- GFToken: https://bscscan.com/address/0xBAD7118C5b445D44Dee72E186D594D315ac7792b
	- addMinter: 0xCEE77C30Cce9BbCD35c0E2B05a414D4941d8572B	GFDistributor
	- addMinter: 0x96e4519B0c0CFc3edAc80Bcef5C5D0361B1A77F8	    GFStaking
- ARTVault: https://bscscan.com/address/0xAa8cD8244843BF3e34dc5A978C29854f6C234643
    - setRecipient：0xbc6a76d3b6e51c7cea5e2063d67220f11699f2da
- GFPriceOracle: https://bscscan.com/address/0x2c1Bd629A23322BD54D403C9139743795903b4F4
    - setPrice
      - 0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424  1.091578 = 3,395.19 / 31.1035 * 100
      - 0xBAD7118C5b445D44Dee72E186D594D315ac7792b	0.001092

### 9. Setup in web page
- GFRegistry
  - Batch Approve KYC 
    - 0xaccount_user_1,0xaccount_user_2
- GFDistributor
  - Allocation Addresses:
    - All： 0xaccount_treasury
    - Set Batch
  - Execute Initial Distribution
- All:
  - Add Admins
- GF:
  - 0xaccount_treasury
    - Approve: 0xCEE77C30Cce9BbCD35c0E2B05a414D4941d8572B
      - 100000000000

ToDo List

- admin list
- distributor approve
- transfer owner (multi sig)
- 
