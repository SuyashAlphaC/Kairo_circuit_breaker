

# Kairo Circuit Breaker 🛡️

An advanced, on-chain security system for Starknet DeFi protocols, designed to prevent economic exploits like flash loan-based accumulator manipulation. This system is battle-tested against a precise recreation of the February 2025 zkLend hack, providing robust, real-time protection for user funds.

## 🎯 Overview

The Kairo Circuit Breaker is not just a simple pause button; it's a sophisticated liquidity monitoring and enforcement system. It operates as a "smart vault" that sits between a DeFi protocol and its users.

By tracking the net flow of assets over a rolling time window, it can automatically detect and neutralize attacks—such as the flash loan "donation" attack used to exploit zkLend. When an anomalous outflow is detected, the breaker trips, locking the attacker's (and subsequent users') funds instead of allowing the exploit to drain the protocol.

This "delayed settlement" mechanism freezes the stolen funds, giving a multi-sig of "Guardians" or the protocol Admin time to review the situation and safely manage the recovery process.

### Key Features

  * **Advanced Rate Limiting**: Monitors net asset flow (inflow vs. outflow) on a per-asset basis, tripping when outflows exceed a configurable percentage of total liquidity within a rolling time window.
  * **Exploit-Specific Prevention**: Explicitly designed to defeat accumulator manipulation and flash loan donation attacks.
  * **Delayed Settlement (Fund Locking)**: On breach, funds are not reverted. They are securely locked within the circuit breaker contract, preventing the attacker from escaping with the capital.
  * **Guardian Multi-Sig**: A decentralized set of Guardians can perform emergency actions, such as pausing the system or proposing and executing a payout of locked funds after an attack.
  * **Mainnet Fork Tested**: The protection mechanism has been proven effective by running tests on a Starknet mainnet fork, precisely replicating and preventing the *exact* zkLend attack sequence.
  * **Modular Integration**: Easily integrated into any protocol using a simple `ProtectedContractComponent` that wraps standard token transfers.

-----

## 🏗️ Architecture

The system works by wrapping a protocol's core deposit and withdrawal functions. All asset flows are routed through the `CircuitBreaker` contract, which consults its internal `Limiter` logic before allowing a transfer.
-----

## 📁 Core Components

  * `src/core/circuit_breaker.cairo`: The main contract that holds all logic, state, and locked funds. It manages asset limiters, protected contracts, and guardian/admin roles.
  * `src/components/protected_contract.cairo`: The simple "plug-and-play" component for integrating a protocol with the circuit breaker.
  * `src/utils/limiter_lib.cairo`: The core rate-limiting logic. It uses a linked list of time-stamped "ticks" to track net liquidity changes over a defined `withdrawal_period`.
  * `src/interfaces/circuit_breaker_interface.cairo`: The public ABI for the circuit breaker.
  * `src/mocks/`: Mock contracts for testing, including:
      * `realistic_zklend_vulnerable.cairo`: A recreation of the vulnerable zkLend contract.
      * `realistic_zklend_protected.cairo`: An example of how to protect the zkLend contract using the `ProtectedContractComponent`.

-----

## 🚀 Quick Start (Integration)

To protect your protocol, you integrate the `ProtectedContractComponent` and use its functions for all token movements.

```cairo
// In your protocol's contract
use circuit_breaker::components::protected_contract::ProtectedContractComponent;

component!(path: ProtectedContractComponent, storage: protected_contract, event: ProtectedContractEvent);

use ProtectedContractComponent::ProtectedContractTrait;
impl ProtectedContractInternalImpl = ProtectedContractComponent::ProtectedContractImpl<ContractState>;

#[constructor]
fn constructor(ref self: ContractState, circuit_breaker_address: ContractAddress) {
    // Link to the deployed CircuitBreaker
    self.protected_contract.set_circuit_breaker(circuit_breaker_address);
}

#[abi(embed_v0)]
impl YourProtocol of IYourProtocol<ContractState> {
    
    // Example: Protected Deposit
    fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
        let caller = get_caller_address();
        let this_contract = get_contract_address();
        
        // Your logic here...
        
        // 1. Use the CB-wrapped transfer for INFLOW
        self.protected_contract.cb_inflow_safe_transfer_from(
            token, caller, this_contract, amount
        );
        
        // Your logic here...
    }

    // Example: Protected Withdrawal
    fn withdraw(ref self: ContractState, token: ContractAddress, amount: u256) {
        let caller = get_caller_address();
        
        // Your logic here...
        
        // 2. Use the CB-wrapped transfer for OUTFLOW
        self.protected_contract.cb_outflow_safe_transfer(
            token, 
            caller, 
            amount, 
            false // false = Don't revert on breach, lock funds instead
        );
        
        // Your logic here...
    }
}
```

-----

## 📋 Core Functions

### Protocol (Integration)

  * `cb_inflow_safe_transfer_from(token, sender, recipient, amount)`: Used for deposits. Transfers funds and notifies the circuit breaker of an *inflow*.
  * `cb_outflow_safe_transfer(token, recipient, amount, revert_on_rate_limit)`: Used for withdrawals. Transfers funds to the circuit breaker, which then checks limits and either sends to the recipient or *locks* the funds.

### Admin Functions

  * `register_asset(asset, threshold_bps, min_amount_to_limit)`: Registers a new token with its specific rate-limiting parameters.
  * `add_protected_contracts(contracts: Array<ContractAddress>)`: Authorizes your protocol contracts to interact with the circuit breaker.
  * `set_guardian_threshold(new_threshold: u32)`: Sets the number of Guardian votes needed to approve a multi-sig action.
  * `override_rate_limit(asset, max_payouts)`: Admin-only function to force-process the payout queue for locked funds.
  * `mark_as_not_operational()`: Pauses the entire system.
  * `migrate_funds_after_exploit(assets, recipient)`: Emergency function to drain all funds from the circuit breaker to a secure recovery address after a catastrophic event.

### Guardian Multi-Sig Functions

  * `guardian_emergency_pause()`: A guardian can unilaterally pause the entire system.
  * `guardian_propose_rate_limit_override(proposal_id)`: Proposes a new payout action to release locked funds.
  * `guardian_vote_rate_limit_override(proposal_id, approve: bool)`: Casts a vote on an active proposal.
  * `execute_guardian_rate_limit_override(proposal_id, asset, max_payouts)`: If a proposal has enough votes, any guardian can execute it, processing the payout queue for the specified asset.

### Public View Functions

  * `is_rate_limited()`: Returns `true` if the circuit breaker has been globally tripped.
  * `is_rate_limit_triggered(asset)`: Checks the status of a specific asset's limiter.
  * `locked_funds(recipient, asset)`: Shows the amount of funds a specific user has locked in the system.
  * `is_guardian(address)`: Checks if an address is a guardian.

-----

## 🧪 Testing

The test suite is a core feature, proving the system's effectiveness against real-world exploits.

  * `tests/test_exact_zklend_hack.cairo`: A self-contained test that:
    1.  Deploys a vulnerable mock of zkLend.
    2.  Executes the *exact* 10-cycle flash loan donation attack to manipulate the lending accumulator.
    3.  Confirms the exploit succeeds and value is extracted.
    4.  Deploys a *protected* version of zkLend.
    5.  Runs the *same attack* and proves the circuit breaker trips, blocks the attack, and contains the value.
  * `tests/test_simple_mainnet_fork.cairo`:
      * Forks Starknet mainnet to the *exact block* of the zkLend hack.
      * Deploys the `CircuitBreaker` and a protected zkLend contract onto this forked state.
      * Uses the *actual attacker's address* to re-run the exploit.
      * Proves that the `CircuitBreaker` successfully detects and prevents the real attack in a live environment.
  * `tests/test_guardian_advanced.cairo`: Verifies the full multi-sig workflow, including proposing, voting (with mixed votes), and executing a fund recovery override.
  * `tests/test_contract.cairo`: Core unit tests for all basic functions, including triggering a rate limit, locking funds, and admin overrides.

-----

## 🛡️ Security & Logic Deep Dive

1.  **Net Flow Tracking**: The `LimiterLib` doesn't just track outflows. It tracks the *net flow* (deposits - withdrawals). This prevents an attacker from "priming" the limit by depositing a large amount and then withdrawing it all. The system tracks net change relative to the *peak liquidity* during the `withdrawal_period`.
2.  **Breach Mechanism**: A breach occurs if `current_liquidity < (peak_liquidity * retention_percentage)`. For example, if a pool has a 70% retention threshold (`min_liq_retained_bps = 7000`) and peaked at 10,000 tokens, the circuit breaker will trip if the liquidity drops below 7,000 tokens within the time window.
3.  **Delayed Settlement**: When the breaker trips (`should_lock_funds = true`), the user's withdrawal is *not* sent to them. Instead, it is added to their `locked_funds` balance and added to a `pending_withdrawals` queue. This is non-reverting and gas-efficient.
4.  **Secure Recovery**: These locked funds are now frozen. They can only be released by a "payout" transaction. This requires a human-in-the-loop (an Admin or the Guardian multi-sig) to assess the situation. An Admin or the Guardians can then execute the payout, which safely processes the queue and sends the (now-verified) funds to the users.

-----

## 🚀 Deployment & Setup

1.  **Build Contracts**: `scarb build`
2.  **Deploy CircuitBreaker**: Deploy `circuit_breaker.cairo`. The constructor requires:
      * `admin`: The main admin/owner address.
      * `rate_limit_cooldown_period`: Time in seconds before a tripped breaker can be reset (e.g., 3 days).
      * `withdrawal_period`: The rolling time window for tracking liquidity (e.g., 4 hours).
      * `tick_length`: The time slice for grouping transactions (e.g., 5 minutes).
      * `eth_token_address`: The address of ETH/WETH for native asset transfers.
3.  **Deploy Your Protocol**: Deploy your contract, passing the `CircuitBreaker`'s address to its constructor.
4.  **Configure CircuitBreaker**:
      * Call `add_protected_contracts()` to whitelist your protocol's address.
      * Call `register_asset()` for each token (e.g., WSTETH, USDC) you want to protect.
      * Call `add_guardian()` to add your multi-sig members.
      * Call `set_guardian_threshold()` to set the number of votes required.

-----

