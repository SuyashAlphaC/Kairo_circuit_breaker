# Kairo Circuit Breaker 🛡️

A modular, plug-and-play Circuit Breaker smart contract system for the Starknet ecosystem, designed to protect DeFi protocols from sudden market shocks.

## 🎯 Overview

The Kairo Circuit Breaker acts as an on-chain "Fire Alarm" for DeFi protocols. When connected to off-chain monitoring systems (the "Smoke Detectors"), it can automatically pause critical functions to protect user funds during market emergencies.

### Key Features

- **EIP-7265 Compliant**: Follows established circuit breaker standards
- **Modular Design**: Easy integration with existing protocols
- **Automated Triggers**: Backend API integration for real-time monitoring
- **Secure Authentication**: Cryptographic signature verification
- **Gas Efficient**: Minimal overhead on protected functions
- **Emergency Overrides**: Critical functions can bypass circuit breaker when needed

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Off-chain     │───▶│  Circuit Breaker │───▶│  Your Protocol  │
│   Monitoring    │    │    Contract      │    │    Contract     │
│   (Backend API) │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌──────────────┐
                       │   Events &   │
                       │ Notifications│
                       └──────────────┘
```

### Components

1. **Circuit Breaker Contract** (`circuit_breaker.cairo`)
   - Core pause/resume functionality
   - Owner management and access control
   - API integration with signature verification

2. **Circuit Breaker Component** (`circuit_breaker_component.cairo`)
   - Reusable component for easy protocol integration
   - Modifier-like functionality for protected functions

3. **Mock Vault Contract** (`mock_vault.cairo`)
   - Example implementation showing integration patterns
   - Demonstrates protected vs emergency functions

## 🚀 Quick Start

### Prerequisites

- Rust (latest stable)
- Scarb (Cairo package manager)
- Starknet Foundry (for testing)
- VS Code with Cairo extension

### Installation

1. **Clone and setup:**
   ```bash
   mkdir kairo_circuit_breaker && cd kairo_circuit_breaker
   scarb init --name kairo_circuit_breaker
   ```

2. **Install dependencies and build:**
   ```bash
   scarb build
   ```

3. **Run tests:**
   ```bash
   snforge test
   ```

### Basic Integration

```cairo
#[starknet::contract]
mod YourProtocol {
    use kairo_circuit_breaker::CircuitBreakerComponent;

    component!(path: CircuitBreakerComponent, storage: circuit_breaker, event: CircuitBreakerEvent);

    #[abi(embed_v0)]
    impl CircuitBreakerComponentImpl = CircuitBreakerComponent::CircuitBreakerComponentImpl<ContractState>;

    // Protect critical functions
    fn withdraw(ref self: ContractState, amount: u256) {
        let function_selector = selector!("withdraw");
        self.circuit_breaker.when_not_paused(function_selector);
        
        // Your withdrawal logic here...
    }
}
```

## 📋 Core Functions

### Circuit Breaker Contract

| Function | Description | Access |
|----------|-------------|--------|
| `pause(target_contract, function_selector)` | Pauses a specific function | Owner only |
| `resume(target_contract, function_selector)` | Resumes a paused function | Owner only |
| `is_paused(target_contract, function_selector)` | Checks if function is paused | Public view |
| `check_and_trip(...)` | Automated trigger from backend API | Public (with signature) |

### Integration Component

| Function | Description | Usage |
|----------|-------------|-------|
| `when_not_paused(function_selector)` | Reverts if function is paused | In protected functions |
| `set_circuit_breaker(address)` | Links to circuit breaker contract | During setup |

## 🧪 Testing

### Run All Tests
```bash
snforge test
```

### Run Specific Tests
```bash
snforge test test_circuit_breaker_deployment
snforge test test_pause_and_resume
snforge test test_mock_vault_integration
```

### Test Coverage

- ✅ Circuit breaker deployment
- ✅ Pause/resume functionality
- ✅ Access control verification
- ✅ Mock vault integration
- ✅ Emergency function bypass
- ✅ Ownership management
- ✅ Event emission

## 📖 API Reference

### Backend Integration

Your monitoring backend should:

1. **Monitor risk factors** (price volatility, liquidity, etc.)
2. **Generate API responses:**
   ```json
   {
     "status": "TRIP"  // or "SAFE"
   }
   ```
3. **Sign responses** with your API key
4. **Call `check_and_trip()`** when threats are detected

### Signature Verification

```python
# Pseudocode for backend
api_response = '{"status": "TRIP"}'
response_hash = poseidon_hash(api_response)
signature = pedersen(api_key_hash, response_hash)
```

## 🛡️ Security Features

### Access Control
- Owner-only pause/resume functions
- Signature verification for API responses
- Secure ownership transfer mechanism

### Circuit Breaker Logic
- Per-function pause granularity
- Emergency override capabilities
- Event logging for transparency

### Best Practices
- Always provide emergency functions
- Implement proper access controls
- Test integration thoroughly
- Monitor gas costs

## 📁 Project Structure

```
kairo_circuit_breaker/
├── src/
│   ├── lib.cairo                           # Main library exports
│   ├── interfaces/
│   │   └── circuit_breaker_interface.cairo # Contract interfaces
│   ├── circuit_breaker.cairo               # Core circuit breaker
│   ├── components/
│   │   └── circuit_breaker_component.cairo # Integration component
│   └── mock/
│       └── mock_vault.cairo                # Example implementation
├── tests/
│   ├── test_circuit_breaker.cairo          # Test suite
│   └── deployment_script.cairo             # Deployment helpers
├── Scarb.toml                              # Project configuration
└── README.md                               # This file
```

## 🚀 Deployment

### Testnet Deployment

1. **Build contracts:**
   ```bash
   scarb build
   ```

2. **Deploy circuit breaker:**
   ```bash
   starkli deploy target/dev/CircuitBreaker.contract_class.json <owner_address> <api_key_hash>
   ```

3. **Deploy your protocol with circuit breaker component**

4. **Link contracts by calling `set_circuit_breaker()`**

### Mainnet Considerations

- Audit all contracts thoroughly
- Test on testnet extensively
- Set up proper monitoring infrastructure
- Have emergency procedures ready
- Consider multi-sig ownership

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## 📊 Gas Estimates

| Function | Gas Cost |
|----------|----------|
| `is_paused()` check | ~3,000 gas |
| `pause()` | ~50,000 gas |
| `resume()` | ~35,000 gas |
| `when_not_paused()` | ~5,000 gas |

## 🔧 Troubleshooting

### Common Issues

1. **"Function is paused by circuit breaker"**
   - Function is currently paused
   - Use emergency function or wait for resume

2. **"Only owner can call this function"**
   - Caller is not the contract owner
   - Check ownership with `get_owner()`

3. **"Invalid signature"**
   - API response signature verification failed
   - Check API key hash and signature generation

### Debug Tips

- Use `scarb build` to check for compilation errors
- Add `println!` statements for debugging tests
- Verify contract addresses are correct
- Check function selectors match exactly

## 📚 Resources

- [Cairo Book](https://book.cairo-lang.org/)
- [Starknet Documentation](https://docs.starknet.io/)
- [EIP-7265 Standard](https://eips.ethereum.org/EIPS/eip-7265)
- [Integration Guide](./docs/integration-guide.md)
- [VS Code Setup Guide](./docs/setup-guide.md)

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙋‍♂️ Support

For questions, issues, or contributions:
- Open an issue on GitHub
- Join the Starknet Discord
- Check the documentation

---

**⚠️ Security Notice**: This is experimental software. Always conduct thorough audits before using in production environments with real funds.