#[starknet::component]
pub mod CircuitBreakerComponent {
    use starknet::{ContractAddress, get_contract_address};
    use core::num::traits::Zero;
    use crate::interfaces::circuit_breaker_interface::{ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait};

    #[storage]
    pub struct Storage {
        circuit_breaker_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        CircuitBreakerSet: CircuitBreakerSet,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CircuitBreakerSet {
        circuit_breaker_address: ContractAddress,
    }
    #[generate_trait]
    pub trait ICircuitBreakerComponent<TContractState> {
        fn set_circuit_breaker(ref self: ComponentState<TContractState>, circuit_breaker_address: ContractAddress);
        fn get_circuit_breaker(self: @ComponentState<TContractState>) -> ContractAddress;
        fn when_not_paused(self: @ComponentState<TContractState>, function_selector: felt252);
    }

    #[abi(embed_v0)]
    impl CircuitBreakerComponentImpl<
        TContractState, +HasComponent<TContractState>
    > of ICircuitBreakerComponent<TContractState> {
        fn set_circuit_breaker(ref self: ComponentState<TContractState>, circuit_breaker_address: ContractAddress) {
            self.circuit_breaker_address.write(circuit_breaker_address);
            
            self.emit(Event::CircuitBreakerSet(CircuitBreakerSet {
                circuit_breaker_address,
            }));
        }

        fn get_circuit_breaker(self: @ComponentState<TContractState>) -> ContractAddress {
            self.circuit_breaker_address.read()
        }

        fn when_not_paused(self: @ComponentState<TContractState>, function_selector: felt252) {
            let circuit_breaker_address = self.circuit_breaker_address.read();
            
            if !circuit_breaker_address.is_zero() {
                let circuit_breaker = ICircuitBreakerDispatcher { contract_address: circuit_breaker_address };
                let current_contract = get_contract_address();
                
                let is_paused = circuit_breaker.is_paused(current_contract, function_selector);
                assert(!is_paused, 'Function is paused ');
            }
        }
    }
}
