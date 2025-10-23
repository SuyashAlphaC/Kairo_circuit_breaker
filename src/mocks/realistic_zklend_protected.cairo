use starknet::ContractAddress;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use crate::mocks::realistic_zklend_vulnerable::{RealisticMarket, RealisticUserPosition};

#[starknet::interface]
pub trait IRealisticZkLendProtected<TContractState> {
    fn initialize_market(ref self: TContractState, token: ContractAddress);
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
    fn borrow(ref self: TContractState, token: ContractAddress, amount: u256);
    fn repay(ref self: TContractState, token: ContractAddress, amount: u256);
    
    // Flash loan functions with circuit breaker protection
    fn flash_loan(ref self: TContractState, token: ContractAddress, amount: u256, callback_data: Array<felt252>);
    fn flash_loan_callback(ref self: TContractState, token: ContractAddress, amount: u256, fee: u256, callback_data: Array<felt252>);
    
    // Circuit breaker management
    fn set_circuit_breaker(ref self: TContractState, circuit_breaker: ContractAddress);
    
    // View functions
    fn get_market(self: @TContractState, token: ContractAddress) -> RealisticMarket;
    fn get_user_position(self: @TContractState, user: ContractAddress, token: ContractAddress) -> RealisticUserPosition;
    fn get_collateral_value(self: @TContractState, user: ContractAddress, token: ContractAddress) -> u256;
    fn get_available_liquidity(self: @TContractState, token: ContractAddress) -> u256;
    fn get_circuit_breaker(self: @TContractState) -> ContractAddress;
}

#[starknet::contract]
pub mod RealisticZkLendProtected {
    use super::{RealisticMarket, RealisticUserPosition};
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use starknet::storage::{Map, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::interfaces::circuit_breaker_interface::{ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait};
    use crate::components::protected_contract::ProtectedContractComponent;
    use core::num::traits::Zero;

    component!(path: ProtectedContractComponent, storage: protected_contract, event: ProtectedContractEvent);

    use ProtectedContractComponent::ProtectedContractTrait;
    impl ProtectedContractInternalImpl = ProtectedContractComponent::ProtectedContractImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        protected_contract: ProtectedContractComponent::Storage,
        markets: Map<ContractAddress, RealisticMarket>,
        user_positions: Map<(ContractAddress, ContractAddress), RealisticUserPosition>,
        admin: ContractAddress,
        flash_loan_in_progress: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        MarketInitialized: MarketInitialized,
        Deposit: Deposit,
        Withdraw: Withdraw,
        Borrow: Borrow,
        Repay: Repay,
        FlashLoan: FlashLoan,
        FlashLoanRepaid: FlashLoanRepaid,
        #[flat]
        ProtectedContractEvent: ProtectedContractComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MarketInitialized {
        #[key]
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub raw_balance_change: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdraw {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub raw_balance_change: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Borrow {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Repay {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FlashLoan {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub fee: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FlashLoanRepaid {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
        pub fee: u256,
        pub donation: u256,
    }


    pub mod Errors {
        pub const MARKET_NOT_INITIALIZED: felt252 = 'Market not initialized';
        pub const MARKET_ALREADY_INITIALIZED: felt252 = 'Market already initialized';
        pub const INSUFFICIENT_LIQUIDITY: felt252 = 'Insufficient liquidity';
        pub const INSUFFICIENT_BALANCE: felt252 = 'Insufficient balance';
        pub const ZERO_AMOUNT: felt252 = 'Amount cannot be zero';
        pub const TRANSFER_FAILED: felt252 = 'Transfer failed';
        pub const FLASH_LOAN_IN_PROGRESS: felt252 = 'Flash loan in progress';
        pub const FLASH_LOAN_NOT_REPAID: felt252 = 'Flash loan not repaid';
    }

    // Constants
    const INITIAL_ACCUMULATOR: u256 = 1000000000000000000; // 1e18
    const FLASH_LOAN_FEE_BPS: u256 = 5; // 0.05%
    
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, circuit_breaker: ContractAddress) {
        self.admin.write(admin);
        self.protected_contract.set_circuit_breaker(circuit_breaker);
    }

    #[abi(embed_v0)]
    impl RealisticZkLendProtectedImpl of super::IRealisticZkLendProtected<ContractState> {
        fn initialize_market(ref self: ContractState, token: ContractAddress) {
            let mut market = self.markets.read(token);
            assert(!market.initialized, Errors::MARKET_ALREADY_INITIALIZED);
            
            market.total_deposits = 0;
            market.total_borrows = 0;
            market.lending_accumulator = INITIAL_ACCUMULATOR;
            market.borrow_accumulator = INITIAL_ACCUMULATOR;
            market.last_update = get_block_timestamp();
            market.initialized = true;
            market.raw_balances = 0;
            
            self.markets.write(token, market);
            
            self.emit(Event::MarketInitialized(MarketInitialized { token }));
        }

        fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            let this_contract = get_contract_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            
            // Use circuit breaker protected transfer
            self.protected_contract.cb_inflow_safe_transfer_from(token, caller, this_contract, amount);
            
            // Same calculation as vulnerable version but protected
            let raw_balance_increase = if market.raw_balances == 0 {
                amount
            } else {
                (amount * market.raw_balances) / market.lending_accumulator
            };
            
            market.total_deposits += amount;
            market.raw_balances += raw_balance_increase;
            self.markets.write(token, market);
            
            let mut user_position = self.user_positions.read((caller, token));
            user_position.raw_balance += raw_balance_increase;
            self.user_positions.write((caller, token), user_position);
            
            self.emit(Event::Deposit(Deposit { 
                user: caller, 
                token, 
                amount, 
                raw_balance_change: raw_balance_increase 
            }));
        }

        fn withdraw(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            
            let mut user_position = self.user_positions.read((caller, token));
            
            // Same vulnerable calculation, but circuit breaker will catch large drains
            let raw_balance_decrease = if market.raw_balances == 0 {
                0
            } else {
                (amount * market.raw_balances) / market.lending_accumulator
            };
            
            let actual_amount = if market.raw_balances == 0 {
                0
            } else {
                (raw_balance_decrease * market.lending_accumulator) / market.raw_balances
            };
            
            assert(user_position.raw_balance >= raw_balance_decrease, Errors::INSUFFICIENT_BALANCE);
            assert(market.total_deposits >= actual_amount, Errors::INSUFFICIENT_LIQUIDITY);
            
            // Update states
            user_position.raw_balance -= raw_balance_decrease;
            market.total_deposits -= actual_amount;
            market.raw_balances -= raw_balance_decrease;
            
            self.user_positions.write((caller, token), user_position);
            self.markets.write(token, market);
            
            // CRITICAL: Use circuit breaker protected transfer
            self.protected_contract.cb_outflow_safe_transfer(token, caller, actual_amount, false);
            
            self.emit(Event::Withdraw(Withdraw { 
                user: caller, 
                token, 
                amount: actual_amount, 
                raw_balance_change: raw_balance_decrease 
            }));
        }

        fn borrow(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            assert(market.total_deposits >= amount, Errors::INSUFFICIENT_LIQUIDITY);
            
            let shares = if market.total_borrows == 0 {
                amount
            } else {
                (amount * market.total_borrows) / market.borrow_accumulator
            };
            
            market.total_borrows += amount;
            self.markets.write(token, market);
            
            let mut user_position = self.user_positions.read((caller, token));
            user_position.borrow_shares += shares;
            self.user_positions.write((caller, token), user_position);
            
            // Protected borrow transfer
            self.protected_contract.cb_outflow_safe_transfer(token, caller, amount, false);
            
            self.emit(Event::Borrow(Borrow { user: caller, token, amount, shares }));
        }

        fn repay(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            let this_contract = get_contract_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            
            let mut user_position = self.user_positions.read((caller, token));
            
            let shares_to_burn = if market.total_borrows == 0 {
                0
            } else {
                (amount * market.total_borrows) / market.borrow_accumulator
            };
            
            assert(user_position.borrow_shares >= shares_to_burn, Errors::INSUFFICIENT_BALANCE);
            
            user_position.borrow_shares -= shares_to_burn;
            market.total_borrows -= amount;
            
            self.user_positions.write((caller, token), user_position);
            self.markets.write(token, market);
            
            // Protected repay transfer
            self.protected_contract.cb_inflow_safe_transfer_from(token, caller, this_contract, amount);
            
            self.emit(Event::Repay(Repay { user: caller, token, amount, shares: shares_to_burn }));
        }

        fn flash_loan(ref self: ContractState, token: ContractAddress, amount: u256, callback_data: Array<felt252>) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            
            assert(!self.flash_loan_in_progress.read(token), Errors::FLASH_LOAN_IN_PROGRESS);
            self.flash_loan_in_progress.write(token, true);
            
            let market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            assert(market.total_deposits >= amount, Errors::INSUFFICIENT_LIQUIDITY);
            
            let fee = (amount * FLASH_LOAN_FEE_BPS) / 10000;
            
            // Use circuit breaker for flash loan transfer
            self.protected_contract.cb_outflow_safe_transfer(token, caller, amount, true); // Mark as flash loan
            
            self.emit(Event::FlashLoan(FlashLoan { user: caller, token, amount, fee }));
            
            self.flash_loan_callback(token, amount, fee, callback_data);
            
            self.flash_loan_in_progress.write(token, false);
        }

        fn flash_loan_callback(ref self: ContractState, token: ContractAddress, amount: u256, fee: u256, callback_data: Array<felt252>) {
            let caller = get_caller_address();
            let this_contract = get_contract_address();
            
            let token_contract = IERC20Dispatcher { contract_address: token };
            let required_repay = amount + fee;
            
            // Transfer the required repayment from caller
            let success = token_contract.transfer_from(caller, this_contract, required_repay);
            assert(success, Errors::TRANSFER_FAILED);
            
            let mut donation: u256 = 0;
            
            // Check for additional donation (simple version)
            if callback_data.len() > 0 {
                let donation_amount = *callback_data.at(0);
                if donation_amount != 0 {
                    donation = donation_amount.into();
                    
                    // Transfer donation
                    let donation_success = token_contract.transfer_from(caller, this_contract, donation);
                    if donation_success {
                        // Apply donation (same vulnerable mechanism)
                        let mut market = self.markets.read(token);
                        market.lending_accumulator += donation;
                        market.total_deposits += donation;
                        self.markets.write(token, market);
                    }
                }
            }
            
            self.emit(Event::FlashLoanRepaid(FlashLoanRepaid { 
                user: caller, 
                token, 
                amount, 
                fee, 
                donation 
            }));
        }

        fn set_circuit_breaker(ref self: ContractState, circuit_breaker: ContractAddress) {
            self.protected_contract.set_circuit_breaker(circuit_breaker);
        }

        // View functions
        fn get_market(self: @ContractState, token: ContractAddress) -> RealisticMarket {
            self.markets.read(token)
        }

        fn get_user_position(self: @ContractState, user: ContractAddress, token: ContractAddress) -> RealisticUserPosition {
            self.user_positions.read((user, token))
        }

        fn get_collateral_value(self: @ContractState, user: ContractAddress, token: ContractAddress) -> u256 {
            let market = self.markets.read(token);
            let position = self.user_positions.read((user, token));
            
            if market.raw_balances == 0 || position.raw_balance == 0 {
                0
            } else {
                (position.raw_balance * market.lending_accumulator) / market.raw_balances
            }
        }

        fn get_available_liquidity(self: @ContractState, token: ContractAddress) -> u256 {
            let market = self.markets.read(token);
            if market.total_deposits > market.total_borrows {
                market.total_deposits - market.total_borrows
            } else {
                0
            }
        }

        fn get_circuit_breaker(self: @ContractState) -> ContractAddress {
            self.protected_contract.get_circuit_breaker()
        }
    }

}