# GoldFinger Smart Contract Development Makefile
# Following BUSD repository structure and practices

.PHONY: help setup ganache compile test coverage deploy deploy-testnet deploy-mainnet flatten lint clean

# Default target
help:
	@echo "Available commands:"
	@echo "  setup          - Install dependencies"
	@echo "  ganache        - Start local blockchain"
	@echo "  compile        - Compile smart contracts"
	@echo "  test           - Run test suite"
	@echo "  coverage       - Generate test coverage report"
	@echo "  deploy         - Deploy to local network"
	@echo "  deploy-testnet - Deploy to BSC testnet"
	@echo "  deploy-mainnet - Deploy to BSC mainnet"
	@echo "  flatten        - Create flattened contracts"
	@echo "  lint           - Run Solidity linter"
	@echo "  lint-fix       - Fix Solidity linting issues"
	@echo "  verify         - Verify contracts on Etherscan/BSCScan"
	@echo "  clean          - Clean build artifacts"

# Setup development environment
setup:
	@echo "Installing dependencies..."
	npm install
	@echo "Setup complete!"

# Start local blockchain
ganache:
	@echo "Starting Ganache CLI..."
	npx ganache-cli --deterministic --accounts 20 --gasLimit 0x1fffffffffffff --allowUnlimitedContractSize

# Compile contracts
compile:
	@echo "Compiling contracts..."
	npx truffle compile

# Run tests
test:
	@echo "Running tests..."
	npx truffle test

# Generate coverage report
coverage:
	@echo "Generating coverage report..."
	npx truffle run coverage

# Deploy to local development network
deploy:
	@echo "Deploying to development network..."
	npx truffle migrate --reset

# Deploy to BSC testnet
deploy-testnet:
	@echo "Deploying to BSC testnet..."
	npx truffle migrate --network bscTestnet --reset

# Deploy to BSC mainnet (use with caution)
deploy-mainnet:
	@echo "Deploying to BSC mainnet..."
	@echo "⚠️  WARNING: This will deploy to mainnet! Press Ctrl+C to cancel or any key to continue..."
	@read -n 1
	npx truffle migrate --network bsc --reset

# Deploy to Ethereum mainnet (use with caution)
deploy-ethereum:
	@echo "Deploying to Ethereum mainnet..."
	@echo "⚠️  WARNING: This will deploy to Ethereum mainnet! Press Ctrl+C to cancel or any key to continue..."
	@read -n 1
	npx truffle migrate --network mainnet --reset

# Create flattened contracts for verification
flatten:
	@echo "Creating flattened contracts..."
	mkdir -p flattened
	npx truffle-flattener contracts/GFToken.sol > flattened/GFToken_flattened.sol
	npx truffle-flattener contracts/ARTToken.sol > flattened/ARTToken_flattened.sol
	npx truffle-flattener contracts/ARTVault.sol > flattened/ARTVault_flattened.sol
	npx truffle-flattener contracts/GFStaking.sol > flattened/GFStaking_flattened.sol
	npx truffle-flattener contracts/GFRegistry.sol > flattened/GFRegistry_flattened.sol
	npx truffle-flattener contracts/GFPriceOracle.sol > flattened/GFPriceOracle_flattened.sol
	npx truffle-flattener contracts/GFDistributor.sol > flattened/GFDistributor_flattened.sol
	@echo "Flattened contracts created in flattened/ directory"

# Run Solidity linter
lint:
	@echo "Running Solidity linter..."
	npx solhint contracts/*.sol

# Fix Solidity linting issues
lint-fix:
	@echo "Fixing Solidity linting issues..."
	npx solhint contracts/*.sol --fix

# Verify contracts (after deployment)
verify:
	@echo "Verifying contracts..."
	@echo "Note: Make sure to set ETHERSCAN_API_KEY and BSCSCAN_API_KEY in .env"
	npx truffle run verify --network bscTestnet

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf build/
	rm -rf coverage/
	rm -rf .nyc_output/
	@echo "Clean complete!"

# Start development environment
dev: setup compile

# Full test suite with coverage
test-full: compile test coverage

# Quick deploy for development
dev-deploy: compile deploy

# Production deployment checklist
prod-check:
	@echo "🔍 Pre-deployment checklist:"
	@echo "1. ✅ Contracts audited"
	@echo "2. ✅ Tests passing (run 'make test')"
	@echo "3. ✅ Coverage > 90% (run 'make coverage')"
	@echo "4. ✅ Linting passes (run 'make lint')"
	@echo "5. ✅ Environment variables set (.env)"
	@echo "6. ✅ Network configuration verified"
	@echo "7. ✅ Gas prices checked"
	@echo "8. ✅ Backup deployment plan ready"
	@echo ""
	@echo "If all items are checked, proceed with deployment."

# Show deployment addresses (after deployment)
addresses:
	@echo "📋 Deployed Contract Addresses:"
	@echo "================================"
	@node -e "const fs = require('fs'); try { const build = JSON.parse(fs.readFileSync('./build/contracts/GFToken.json')); console.log('GFToken:', build.networks[Object.keys(build.networks)[0]].address); } catch(e) { console.log('GFToken: Not deployed'); }"
	@node -e "const fs = require('fs'); try { const build = JSON.parse(fs.readFileSync('./build/contracts/ARTToken.json')); console.log('ARTToken:', build.networks[Object.keys(build.networks)[0]].address); } catch(e) { console.log('ARTToken: Not deployed'); }"
	@node -e "const fs = require('fs'); try { const build = JSON.parse(fs.readFileSync('./build/contracts/ARTVault.json')); console.log('ARTVault:', build.networks[Object.keys(build.networks)[0]].address); } catch(e) { console.log('ARTVault: Not deployed'); }"