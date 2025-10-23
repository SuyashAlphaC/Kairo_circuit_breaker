// Core modules
pub mod core {
    pub mod circuit_breaker;
}

// Interfaces
pub mod interfaces {
    pub mod circuit_breaker_interface;
}

// Components
pub mod components {
    pub mod protected_contract;
}

// Types and utilities
pub mod types {
    pub mod structs;
}

pub mod utils {
    pub mod limiter_lib;
}

// Mocks for testing
pub mod mocks {
    pub mod mock_token;
    pub mod mock_defi_protocol;
    pub mod realistic_zklend_vulnerable;
    pub mod realistic_zklend_protected;
    pub mod flash_loan_attacker;
}


pub use core::circuit_breaker::CircuitBreaker;
pub use interfaces::circuit_breaker_interface::{
    ICircuitBreaker, ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait
};
pub use components::protected_contract::ProtectedContractComponent;
pub use types::structs::{Limiter, LiqChangeNode, SignedU256, LimitStatus, SignedU256Trait, GuardianOverrideProposal};
pub use utils::limiter_lib::{LimiterLibTrait, LimiterLibImpl};
pub use mocks::mock_token::{MockToken};
pub use mocks::mock_defi_protocol::{
    MockDeFiProtocol, IMockDeFiProtocol, IMockDeFiProtocolDispatcher, IMockDeFiProtocolDispatcherTrait
};
pub use mocks::realistic_zklend_vulnerable::{
    RealisticZkLendVulnerable, IRealisticZkLendVulnerable, IRealisticZkLendVulnerableDispatcher, IRealisticZkLendVulnerableDispatcherTrait
};
pub use mocks::realistic_zklend_protected::{
    RealisticZkLendProtected, IRealisticZkLendProtected, IRealisticZkLendProtectedDispatcher, IRealisticZkLendProtectedDispatcherTrait
};