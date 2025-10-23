// Realistic zkLend protocol implementation that replicates the exact February 2025 hack
// This includes the flash loan donation mechanism and precise accumulator manipulation vulnerabilities

use starknet::ContractAddress;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct RealisticMarket {
    pub total_deposits: u256,
    pub total_borrows: u256,
    pub lending_accumulator: u256,  // This is the key vulnerability target
    pub borrow_accumulator: u256,
    pub last_update: u64,
    pub initialized: bool,
    pub raw_balances: u256, // Total raw balance units - critical for the exploit
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct RealisticUserPosition {
    pub raw_balance: u256,  // Raw balance units - this gets manipulated in the hack
    pub borrow_shares: u256,
}

#[starknet::interface]
pub trait IRealisticZkLendVulnerable<TContractState> {
    fn initialize_market(ref self: TContractState, token: ContractAddress);
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw(ref self: TContractState, token: ContractAddress, amount: u256);
    fn borrow(ref self: TContractState, token: ContractAddress, amount: u256);
    fn repay(ref self: TContractState, token: ContractAddress, amount: u256);
    
    // Flash loan functions - KEY to the exploit
    fn flash_loan(ref self: TContractState, token: ContractAddress, amount: u256, callback_data: Array<felt252>);
    fn flash_loan_callback(ref self: TContractState, token: ContractAddress, amount: u256, fee: u256, callback_data: Array<felt252>);
    
    // View functions
    fn get_market(self: @TContractState, token: ContractAddress) -> RealisticMarket;
    fn get_user_position(self: @TContractState, user: ContractAddress, token: ContractAddress) -> RealisticUserPosition;
    fn get_collateral_value(self: @TContractState, user: ContractAddress, token: ContractAddress) -> u256;
    fn get_available_liquidity(self: @TContractState, token: ContractAddress) -> u256;
}

#[starknet::contract]
pub mod RealisticZkLendVulnerable {
    use super::{RealisticMarket, RealisticUserPosition, IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use starknet::storage::{Map, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        markets: Map<ContractAddress, RealisticMarket>,
        user_positions: Map<(ContractAddress, ContractAddress), RealisticUserPosition>,
        admin: ContractAddress,
        flash_loan_in_progress: Map<ContractAddress, bool>, // Prevent reentrancy
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
        AccumulatorManipulated: AccumulatorManipulated,
        RawBalanceManipulated: RawBalanceManipulated,
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
        pub donation: u256, // CRITICAL: This is the exploit mechanism
    }

    #[derive(Drop, starknet::Event)]
    pub struct AccumulatorManipulated {
        #[key]
        pub token: ContractAddress,
        pub old_accumulator: u256,
        pub new_accumulator: u256,
        pub manipulation_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RawBalanceManipulated {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub old_raw_balance: u256,
        pub new_raw_balance: u256,
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

    // Constants that enable the vulnerability
    const INITIAL_ACCUMULATOR: u256 = 1000000000000000000; // 1e18 - starts at 1.0
    const FLASH_LOAN_FEE_BPS: u256 = 5; // 0.05% fee
    
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.admin.write(admin);
    }

    #[abi(embed_v0)]
    impl RealisticZkLendVulnerableImpl of super::IRealisticZkLendVulnerable<ContractState> {
        fn initialize_market(ref self: ContractState, token: ContractAddress) {
            let mut market = self.markets.read(token);
            assert(!market.initialized, Errors::MARKET_ALREADY_INITIALIZED);
            
            // VULNERABILITY: Empty market allows manipulation
            market.total_deposits = 0;
            market.total_borrows = 0;
            market.lending_accumulator = INITIAL_ACCUMULATOR; // Starts at exactly 1e18
            market.borrow_accumulator = INITIAL_ACCUMULATOR;
            market.last_update = get_block_timestamp();
            market.initialized = true;
            market.raw_balances = 0; // No raw balances initially
            
            self.markets.write(token, market);
            self.emit(Event::MarketInitialized(MarketInitialized { token }));
        }

        fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            let this_contract = get_contract_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            
            // Transfer tokens first
            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer_from(caller, this_contract, amount);
            assert(success, Errors::TRANSFER_FAILED);
            
            // CRITICAL VULNERABILITY: Raw balance calculation with integer division
            let raw_balance_increase = if market.raw_balances == 0 {
                amount  // First deposit gets 1:1 ratio
            } else {
                // This division can be exploited through accumulator manipulation
                (amount * market.raw_balances) / market.lending_accumulator
            };
            
            // Update market state
            market.total_deposits += amount;
            market.raw_balances += raw_balance_increase;
            self.markets.write(token, market);
            
            // Update user position
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
            
            // CRITICAL VULNERABILITY: Integer division with floor rounding
            let raw_balance_decrease = if market.raw_balances == 0 {
                0
            } else {
                // This calculation is exploitable: division truncates, allowing value extraction
                (amount * market.raw_balances) / market.lending_accumulator
            };
            
            // Calculate actual amount based on truncated raw_balance_decrease
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
            
            // Transfer tokens - note: actual_amount might be less than requested due to rounding
            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer(caller, actual_amount);
            assert(success, Errors::TRANSFER_FAILED);
            
            self.emit(Event::Withdraw(Withdraw { 
                user: caller, 
                token, 
                amount: actual_amount, 
                raw_balance_change: raw_balance_decrease 
            }));

            // Emit manipulation event if there's a discrepancy
            if actual_amount != amount {
                let old_raw_balance = user_position.raw_balance + raw_balance_decrease;
                self.emit(Event::RawBalanceManipulated(RawBalanceManipulated {
                    user: caller,
                    token,
                    old_raw_balance,
                    new_raw_balance: user_position.raw_balance,
                }));
            }
        }

        fn borrow(ref self: ContractState, token: ContractAddress, amount: u256) {
            assert(amount > 0, Errors::ZERO_AMOUNT);
            let caller = get_caller_address();
            
            let mut market = self.markets.read(token);
            assert(market.initialized, Errors::MARKET_NOT_INITIALIZED);
            assert(market.total_deposits >= amount, Errors::INSUFFICIENT_LIQUIDITY);
            
            // Standard borrow shares calculation
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
            
            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer(caller, amount);
            assert(success, Errors::TRANSFER_FAILED);
            
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
            
            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer_from(caller, this_contract, amount);
            assert(success, Errors::TRANSFER_FAILED);
            
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
            
            // Transfer tokens to caller
            let token_contract = IERC20Dispatcher { contract_address: token };
            let success = token_contract.transfer(caller, amount);
            assert(success, Errors::TRANSFER_FAILED);
            
            self.emit(Event::FlashLoan(FlashLoan { user: caller, token, amount, fee }));
            
            // Call back to user - they must repay amount + fee
            self.flash_loan_callback(token, amount, fee, callback_data);
            
            self.flash_loan_in_progress.write(token, false);
        }

        fn flash_loan_callback(ref self: ContractState, token: ContractAddress, amount: u256, fee: u256, callback_data: Array<felt252>) {
            // In the real implementation, this would be called by the flash loan contract
            // For simplicity, we handle the repayment check here
            let caller = get_caller_address();
            let this_contract = get_contract_address();
            
            let token_contract = IERC20Dispatcher { contract_address: token };
            let required_repay = amount + fee;
            
            // Transfer the required repayment from caller
            let success = token_contract.transfer_from(caller, this_contract, required_repay);
            assert(success, Errors::TRANSFER_FAILED);
            
            // Check for additional donation (this is where the exploit happens)
            // In the real hack, attackers would send extra tokens
            if callback_data.len() > 0 {
                let donation_amount = *callback_data.at(0);
                if donation_amount != 0 {
                    // Transfer additional donation
                    let donation_success = token_contract.transfer_from(caller, this_contract, donation_amount.into());
                    if donation_success {
                        // CRITICAL VULNERABILITY: Process the donation
                        self._process_donation(token, donation_amount.into());
                    }
                }
            }
            
            self.emit(Event::FlashLoanRepaid(FlashLoanRepaid { 
                user: caller, 
                token, 
                amount, 
                fee, 
                donation: if callback_data.len() > 0 { (*callback_data.at(0)).into() } else { 0 }
            }));
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
                // This calculation becomes inflated when accumulator is manipulated
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
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _process_donation(ref self: ContractState, token: ContractAddress, donation: u256) {
            let mut market = self.markets.read(token);
            let old_accumulator = market.lending_accumulator;
            
            // CRITICAL VULNERABILITY: This is the exact mechanism from the real hack
            // Donations inflate the lending accumulator, making deposits appear more valuable
            market.lending_accumulator += donation;
            market.total_deposits += donation;
            
            self.markets.write(token, market);
            
            self.emit(Event::AccumulatorManipulated(AccumulatorManipulated {
                token,
                old_accumulator,
                new_accumulator: market.lending_accumulator,
                manipulation_amount: donation,
            }));
        }
    }
}