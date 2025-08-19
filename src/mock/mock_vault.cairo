#[starknet::interface]
pub trait IMockVault<TContractState> {
    fn deposit(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, amount: u256);
    fn get_balance(self: @TContractState, user: starknet::ContractAddress) -> u256;
    fn get_total_deposits(self: @TContractState) -> u256;
    fn set_circuit_breaker(ref self: TContractState, circuit_breaker_address: starknet::ContractAddress);
    fn emergency_withdraw(ref self: TContractState, amount: u256);
}

#[starknet::contract]
pub mod MockVault {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::Map;

    use crate::components::circuit_breaker_component::CircuitBreakerComponent;
    use crate::components::circuit_breaker_component::CircuitBreakerComponent::ICircuitBreakerComponent;
    use crate::interfaces::circuit_breaker_interface::ICircuitBreaker;
    use core::starknet::contract_address;
    use super::IMockVault;

    use core::integer::u256;
   

    component!(path: CircuitBreakerComponent, storage: circuit_breaker, event: CircuitBreakerEvent);

    #[storage]
    struct Storage {
        balances: Map<ContractAddress, u256>,
        total_deposits: u256,
        owner: ContractAddress,
        #[substorage(v0)]
        circuit_breaker: CircuitBreakerComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        EmergencyWithdrawal: EmergencyWithdrawal,
        #[flat]
        CircuitBreakerEvent: CircuitBreakerComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        user: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        user: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct EmergencyWithdrawal {
        user: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl MockVaultImpl of IMockVault<ContractState> {
        fn deposit(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let current_balance = self.balances.read(caller);
            let new_balance = current_balance + amount;
            self.balances.write(caller, new_balance);

            let new_total = self.total_deposits.read() +  amount;
            self.total_deposits.write(new_total);

            self.emit(Event::Deposit(Deposit { user: caller, amount }));
        }

        fn withdraw(ref self: ContractState, amount: u256) {
          
            let function_selector = starknet::selector!("withdraw");
            self.circuit_breaker.when_not_paused(function_selector);

            let caller = get_caller_address();
            let current_balance = self.balances.read(caller);

            assert(current_balance >= amount, 'Insufficient balance');

            let new_balance = current_balance - amount;
            self.balances.write(caller, new_balance);

            let new_total = self.total_deposits.read() -  amount;
            self.total_deposits.write(new_total);

            self.emit(Event::Withdrawal(Withdrawal { user: caller, amount }));
        }

        fn get_balance(self: @ContractState, user: ContractAddress) -> u256 {
            self.balances.read(user)
        }

        fn get_total_deposits(self: @ContractState) -> u256 {
            self.total_deposits.read()
        }

        fn set_circuit_breaker(ref self: ContractState, circuit_breaker_address: ContractAddress) {
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'Not owner');

            self.circuit_breaker.set_circuit_breaker(circuit_breaker_address);
        }

        fn emergency_withdraw(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let current_balance = self.balances.read(caller);

            assert(current_balance >= amount, 'Insufficient balance');

            let new_balance = current_balance - amount;
            self.balances.write(caller, new_balance);

            let new_total = self.total_deposits.read() - amount;
            self.total_deposits.write(new_total);

            self.emit(Event::EmergencyWithdrawal(EmergencyWithdrawal { user: caller, amount }));
        }
    }
}
