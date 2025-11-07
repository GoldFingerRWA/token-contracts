# Contract Specifications

## Overview

This directory contains the smart contract specifications and documentation for the GoldFinger ecosystem.

## Contract Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│    GFToken      │    │    ARTToken     │    │   GFRegistry    │
│   (Governance)  │    │  (Asset Token)  │    │   (Registry)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
         ┌─────────────────┬─────┴─────┬─────────────────┐
         │                 │           │                 │
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   GFStaking     │ │   ARTVault      │ │ GFPriceOracle   │ │ GFDistributor   │
│   (Staking)     │ │   (Vault)       │ │   (Oracle)      │ │ (Distribution)  │
└─────────────────┘ └─────────────────┘ └─────────────────┘ └─────────────────┘
```

## Token Specifications

### GFToken (GF)
- **Type**: ERC20 Governance Token
- **Decimals**: 6
- **Total Supply**: 100,000,000,000 GF
- **Features**: Voting, Delegation, Permit, Pausable, Blacklist

### ARTToken (ART)
- **Type**: ERC20 Asset-backed Token
- **Decimals**: 18
- **Features**: Mintable, Burnable, Pausable

## Security Features

### Access Control
- **Owner**: Can pause, manage admins
- **Admin**: Can manage minters, blacklist addresses
- **Minter**: Can mint tokens (within supply cap)

### Compliance
- **Blacklist**: Prevent transfers to/from blacklisted addresses
- **Pausable**: Emergency stop functionality
- **Supply Cap**: Maximum supply enforcement

### Emergency Functions
- **Admin Burn**: Burn tokens from blacklisted addresses
- **Rescue**: Recover accidentally sent tokens

## Deployment Checklist

- [ ] Contracts compiled successfully
- [ ] All tests passing
- [ ] Test coverage > 90%
- [ ] Security audit completed
- [ ] Deployment parameters verified
- [ ] Network configuration confirmed
- [ ] Gas prices optimized
- [ ] Verification scripts prepared