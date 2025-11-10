# GoldFinger (GF) Token Ecosystem

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-blue.svg)](https://soliditylang.org/)

The GoldFinger token ecosystem smart contracts - a comprehensive DeFi platform featuring governance tokens, staking mechanisms, vaults, and oracle price feeds.

## 🏗️ Architecture Overview

The GoldFinger ecosystem consists of several interconnected smart contracts:

- **GFToken** (`GFToken.sol`) - The main governance token
- **ARTToken** (`ARTToken.sol`) - Asset-backed token for the ecosystem
- **ARTVault** (`ARTVault.sol`) - Vault contract for asset management
- **GFStaking** (`GFStaking.sol`) - Staking rewards and governance
- **GFRegistry** (`GFRegistry.sol`) - Central registry for contract addresses
- **GFPriceOracle** (`GFPriceOracle.sol`) - Price oracle for asset valuations
- **GFDistributor** (`GFDistributor.sol`) - Token distribution mechanism

## 🚀 Getting Started

### Prerequisites

- Node.js >= 16.0.0
- npm or yarn
- Git

### Installation

1. Clone the repository:
```bash
git clone https://github.com/GoldFingerRWA/token-contracts.git
cd token-contracts
```

2. Install dependencies:
```bash
make setup
# or manually:
npm install
```

## 🔧 Development

### Compile Contracts

```bash
make compile
# or
npm run compile
```

### Run Tests

```bash
make test
# or
npm run test
```

### Coverage Report

```bash
make coverage
# or
npm run coverage
```

### Deploy Contracts

For local development:
```bash
make ganache  # In one terminal
make deploy   # In another terminal
```

For testnet/mainnet:
```bash
npm run migrate -- --network bscTestnet
npm run migrate -- --network bsc
```

## 🌐 Deployed Contracts

### BSC Mainnet

| Contract | Address | Verification |
|----------|---------|--------------|
| ARTToken | [`0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424`](https://bscscan.com/address/0x0B3f46FcC5f3AC3ac1b28BED8336060679c67424) | ✅ Verified |
| GFToken | [`0xBAD7118C5b445D44Dee72E186D594D315ac7792b`](https://bscscan.com/address/0xBAD7118C5b445D44Dee72E186D594D315ac7792b) | ✅ Verified |
| GFPriceOracle | [`0x2c1Bd629A23322BD54D403C9139743795903b4F4`](https://bscscan.com/address/0x2c1Bd629A23322BD54D403C9139743795903b4F4) | ✅ Verified |
| GFRegistry | [`0xD1aB3Ba1882E7F2A1DE63849048Ed20a97F17A9a`](https://bscscan.com/address/0xD1aB3Ba1882E7F2A1DE63849048Ed20a97F17A9a) | ✅ Verified |
| ARTVault | [`0xAa8cD8244843BF3e34dc5A978C29854f6C234643`](https://bscscan.com/address/0xAa8cD8244843BF3e34dc5A978C29854f6C234643) | ✅ Verified |
| GFDistributor | [`0xCEE77C30Cce9BbCD35c0E2B05a414D4941d8572B`](https://bscscan.com/address/0xCEE77C30Cce9BbCD35c0E2B05a414D4941d8572B) | ✅ Verified |
| GFStaking | [`0x96e4519B0c0CFc3edAc80Bcef5C5D0361B1A77F8`](https://bscscan.com/address/0x96e4519B0c0CFc3edAc80Bcef5C5D0361B1A77F8) | ✅ Verified |

### Reference Assets

- **USDT**: [`0x55d398326f99059fF775485246999027B3197955`](https://bscscan.com/token/0x55d398326f99059fF775485246999027B3197955)
- **USDC**: [`0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d`](https://bscscan.com/token/0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d)

## 📁 Project Structure

```
├── contracts/          # Smart contract source files
├── migrations/         # Deployment scripts
├── test/              # Test files
├── scripts/           # Utility scripts
├── docs/              # Documentation
├── flattened/         # Flattened contracts for verification
├── audit-reports/     # Security audit reports
├── truffle-config.js  # Truffle configuration
├── package.json       # NPM dependencies and scripts
├── Makefile          # Build automation
└── README.md         # This file
```

## 🔐 Security

### Audits

- Security audit reports are stored in the [`audit-reports/`](./audit-reports/) directory
- All contracts follow OpenZeppelin security best practices
- Comprehensive test coverage with edge case testing

### Bug Bounty

We encourage responsible disclosure of security vulnerabilities. Please contact our security team before publishing any vulnerabilities.

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- Email: [info@goldfinger.finance](mailto:info@goldfinger.finance)
- Website: [https://goldfinger.finance](https://goldfinger.finance)
- Twitter: [@GoldFingerRWA](https://twitter.com/GoldFingerRWA)
- Telegram: [GoldFinger Community](https://t.me/GoldFinger_Official)
- Discord: [Community Discord](https://discord.gg/goldfinger)
- GitHub: [GoldFinger Organization](https://github.com/GoldFingerRWA)
