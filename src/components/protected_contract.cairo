// src/components/protected_contract.cairo

#[starknet::component]
pub mod ProtectedContractComponent {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use core::num::traits::Zero;
    use starknet::ContractAddress;
    use crate::interfaces::circuit_breaker_interface::{ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    #[storage]
    pub struct Storage {
        circuit_breaker: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        CircuitBreakerSet: CircuitBreakerSet,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CircuitBreakerSet {
        pub circuit_breaker: ContractAddress,
    }

    pub mod Errors {
        pub const CIRCUIT_BREAKER_NOT_SET: felt252 = 'Circuit breaker not set';
        pub const TRANSFER_FAILED: felt252 = 'Transfer failed';
    }

    #[generate_trait]
    pub impl ProtectedContractImpl<
        TContractState, +HasComponent<TContractState>
    > of ProtectedContractTrait<TContractState> {
        fn set_circuit_breaker(
            ref self: ComponentState<TContractState>,
            circuit_breaker: ContractAddress
        ) {
            self.circuit_breaker.write(circuit_breaker);
            self.emit(Event::CircuitBreakerSet(CircuitBreakerSet { circuit_breaker }));
        }

        fn get_circuit_breaker(self: @ComponentState<TContractState>) -> ContractAddress {
            self.circuit_breaker.read()
        }

        fn cb_inflow_safe_transfer_from(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            // Transfer tokens safely from sender to recipient
            let erc20 = IERC20Dispatcher { contract_address: token };
            let success = erc20.transfer_from(sender, recipient, amount);
            assert(success, Errors::TRANSFER_FAILED);

            // Record inflow with circuit breaker
            let circuit_breaker_address = self.circuit_breaker.read();
            assert(!circuit_breaker_address.is_zero(), Errors::CIRCUIT_BREAKER_NOT_SET);
            
            let circuit_breaker = ICircuitBreakerDispatcher { contract_address: circuit_breaker_address };
            circuit_breaker.on_token_inflow(token, amount);
        }

        fn cb_outflow_safe_transfer(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
            revert_on_rate_limit: bool
        ) {
            let circuit_breaker_address = self.circuit_breaker.read();
            assert(!circuit_breaker_address.is_zero(), Errors::CIRCUIT_BREAKER_NOT_SET);

            // Transfer tokens to circuit breaker first
            let erc20 = IERC20Dispatcher { contract_address: token };
            let success = erc20.transfer(circuit_breaker_address, amount);
            assert(success, Errors::TRANSFER_FAILED);

            // Let circuit breaker handle the outflow
            let circuit_breaker = ICircuitBreakerDispatcher { contract_address: circuit_breaker_address };
            circuit_breaker.on_token_outflow(token, amount, recipient, revert_on_rate_limit);
        }

        fn cb_inflow_native(ref self: ComponentState<TContractState>, amount: u256) {
            let circuit_breaker_address = self.circuit_breaker.read();
            assert(!circuit_breaker_address.is_zero(), Errors::CIRCUIT_BREAKER_NOT_SET);
            
            let circuit_breaker = ICircuitBreakerDispatcher { contract_address: circuit_breaker_address };
            circuit_breaker.on_native_asset_inflow(amount);
        }

        fn cb_outflow_native(
            ref self: ComponentState<TContractState>,
            recipient: ContractAddress,
            amount: u256,
            revert_on_rate_limit: bool
        ) {
            let circuit_breaker_address = self.circuit_breaker.read();
            assert(!circuit_breaker_address.is_zero(), Errors::CIRCUIT_BREAKER_NOT_SET);

            let circuit_breaker = ICircuitBreakerDispatcher { contract_address: circuit_breaker_address };
            circuit_breaker.on_native_asset_outflow(recipient, revert_on_rate_limit);
        }
    }
}