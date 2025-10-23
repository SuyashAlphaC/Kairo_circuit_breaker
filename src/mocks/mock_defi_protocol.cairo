#[starknet::interface]
pub trait IMockDeFiProtocol<TContractState> {
    fn deposit(ref self: TContractState, token: starknet::ContractAddress, amount: u256);
    fn withdrawal(ref self: TContractState, token: starknet::ContractAddress, amount: u256);
    fn deposit_no_circuit_breaker(ref self: TContractState, token: starknet::ContractAddress, amount: u256);
    fn deposit_native(ref self: TContractState, amount: u256);
    fn withdrawal_native(ref self: TContractState, amount: u256);
    fn set_circuit_breaker(ref self: TContractState, circuit_breaker: starknet::ContractAddress);
}

#[starknet::contract]
pub mod MockDeFiProtocol {
    use starknet::{ContractAddress, get_caller_address};
    use crate::components::protected_contract::ProtectedContractComponent;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    component!(path: ProtectedContractComponent, storage: protected_contract, event: ProtectedContractEvent);

    // Import the internal implementation
    use ProtectedContractComponent::ProtectedContractTrait;
    impl ProtectedContractInternalImpl = ProtectedContractComponent::ProtectedContractImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        protected_contract: ProtectedContractComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdrawal: Withdrawal,
        DepositNative: DepositNative,
        WithdrawalNative: WithdrawalNative,
        #[flat]
        ProtectedContractEvent: ProtectedContractComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        pub token: ContractAddress,
        pub user: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        pub token: ContractAddress,
        pub user: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DepositNative {
        pub user: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalNative {
        pub user: ContractAddress,
        pub amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, circuit_breaker: ContractAddress) {
        self.protected_contract.set_circuit_breaker(circuit_breaker);
    }

    #[abi(embed_v0)]
    impl MockDeFiProtocolImpl of super::IMockDeFiProtocol<ContractState> {
        fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let this_contract = starknet::get_contract_address();
            
            // Use circuit breaker protected transfer
            self.protected_contract.cb_inflow_safe_transfer_from(
                token, 
                caller, 
                this_contract, 
                amount
            );
            
            self.emit(Event::Deposit(Deposit { token, user: caller, amount }));
        }

        fn withdrawal(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            
            // Use circuit breaker protected transfer with delayed settlement
            self.protected_contract.cb_outflow_safe_transfer(
                token, 
                caller, 
                amount, 
                false // Don't revert on rate limit, use delayed settlement
            );
            
            self.emit(Event::Withdrawal(Withdrawal { token, user: caller, amount }));
        }

        fn deposit_no_circuit_breaker(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let this_contract = starknet::get_contract_address();
            
            // Direct transfer without circuit breaker (for gas comparison)
            let erc20 = IERC20Dispatcher { contract_address: token };
            let success = erc20.transfer_from(caller, this_contract, amount);
            assert(success, 'Transfer failed');
            
            self.emit(Event::Deposit(Deposit { token, user: caller, amount }));
        }

        fn deposit_native(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            
            self.protected_contract.cb_inflow_native(amount);
            
            self.emit(Event::DepositNative(DepositNative { user: caller, amount }));
        }

        fn withdrawal_native(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            
            self.protected_contract.cb_outflow_native(caller, amount, false);
            
            self.emit(Event::WithdrawalNative(WithdrawalNative { user: caller, amount }));
        }

        fn set_circuit_breaker(ref self: ContractState, circuit_breaker: ContractAddress) {
            self.protected_contract.set_circuit_breaker(circuit_breaker);
        }
    }
}