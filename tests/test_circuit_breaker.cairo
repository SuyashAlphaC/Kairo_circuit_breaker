use core::array::ArrayTrait;
use core::traits::Into;
use core::byte_array::ByteArrayTrait;
use starknet::{ContractAddress, contract_address_const};
use core::pedersen::pedersen;
use core::hash::HashStateTrait;
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
    CheatSpan
};


use kairo_circuit_breaker::interfaces::circuit_breaker_interface::{
    ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait
};
use kairo_circuit_breaker::mock::mock_vault::{
    IMockVaultDispatcher, IMockVaultDispatcherTrait
};

const OWNER: felt252 = 'owner';
const USER: felt252 = 'user';
const NON_OWNER: felt252 = 'non_owner';
const API_KEY_HASH: felt252 = 'api_key_hash';
const DEPOSIT_AMOUNT: u256 = 1000;
const WITHDRAW_AMOUNT: u256 = 500;

fn get_owner_address() -> ContractAddress {
    contract_address_const::<OWNER>()
}

fn get_user_address() -> ContractAddress {
    contract_address_const::<USER>()
}

fn get_non_owner_address() -> ContractAddress {
    contract_address_const::<NON_OWNER>()
}
fn deploy_circuit_breaker() -> (ICircuitBreakerDispatcher, ContractAddress) {
    let owner_address = get_owner_address();
    
    let contract = declare("CircuitBreaker").unwrap().contract_class();
    let constructor_args = array![owner_address.into(), API_KEY_HASH];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    
    let dispatcher = ICircuitBreakerDispatcher { contract_address };
    (dispatcher, contract_address)
}

fn deploy_mock_vault() -> (IMockVaultDispatcher, ContractAddress) {
    let owner_address = get_owner_address();
    
    let contract = declare("MockVault").unwrap().contract_class();
    let constructor_args = array![owner_address.into()];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    
    let dispatcher = IMockVaultDispatcher { contract_address };
    (dispatcher, contract_address)
}


fn setup_complete_system() -> (ICircuitBreakerDispatcher, IMockVaultDispatcher, ContractAddress, ContractAddress) {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let (mock_vault, mock_vault_address) = deploy_mock_vault();
    
    // Link the vault to circuit breaker as owner
    start_cheat_caller_address(mock_vault_address, get_owner_address());
    mock_vault.set_circuit_breaker(circuit_breaker_address);
    stop_cheat_caller_address(mock_vault_address);
    
    (circuit_breaker, mock_vault, circuit_breaker_address, mock_vault_address)
}

fn create_api_signature(api_response: @ByteArray) -> Array<felt252> {
   
    let response_hash = hash_byte_array_for_test(api_response);
    
    let signature = core::pedersen::pedersen(API_KEY_HASH, response_hash);
    array![signature]
}

fn hash_byte_array_for_test(data: @ByteArray) -> felt252 {
    let mut hasher = core::poseidon::PoseidonTrait::new();
    
    hasher = hasher.update(data.len().into());
    let mut i = 0;
    while i < data.len() {
        if i + 31 < data.len() {
            
            let chunk = data.at(i).unwrap().into();
            hasher = hasher.update(chunk);
            i += 31;
        } else {
           
            let chunk = data.at(i).unwrap().into();
            hasher = hasher.update(chunk);
            i += 1;
        }
    };
    
    hasher.finalize()
}


#[test]
fn test_circuit_breaker_deployment() {
    let (circuit_breaker, _) = deploy_circuit_breaker();
    
    let owner = circuit_breaker.get_owner();
    assert(owner == get_owner_address(), 'Wrong owner');
}

#[test]
fn test_mock_vault_deployment() {
    let (mock_vault, _) = deploy_mock_vault();
    
  
    let balance = mock_vault.get_balance(get_user_address());
    assert(balance == 0, 'Initial balance should be 0');
    
    let total_deposits = mock_vault.get_total_deposits();
    assert(total_deposits == 0, 'Initial deposits should be 0');
}

#[test]
fn test_vault_basic_operations() {
    let (mock_vault, mock_vault_address) = deploy_mock_vault();
    let user_address = get_user_address();
   
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.deposit(DEPOSIT_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    let balance = mock_vault.get_balance(user_address);
    assert(balance == DEPOSIT_AMOUNT, 'Deposit failed');
    
    let total_deposits = mock_vault.get_total_deposits();
    assert(total_deposits == DEPOSIT_AMOUNT, 'Total deposits wrong');
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.withdraw(WITHDRAW_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    let balance_after = mock_vault.get_balance(user_address);
    let expected_balance = DEPOSIT_AMOUNT - WITHDRAW_AMOUNT;
    assert(balance_after == expected_balance, 'Withdraw failed');
}

#[test]
fn test_circuit_breaker_pause_resume() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let mock_vault_address = contract_address_const::<'vault'>();
    let function_selector = starknet::selector!("withdraw");

    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused, 'Should not be paused initially');
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(is_paused, 'Should be paused');
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.resume(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused, 'Paused after resume ');
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_only_owner_can_pause() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let mock_vault_address = contract_address_const::<'vault'>();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(circuit_breaker_address, get_non_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_only_owner_can_resume() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let mock_vault_address = contract_address_const::<'vault'>();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    start_cheat_caller_address(circuit_breaker_address, get_non_owner_address());
    circuit_breaker.resume(mock_vault_address, function_selector);
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_only_owner_can_update_api_key() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let new_api_key_hash: felt252 = 'new_api_key';
    
    start_cheat_caller_address(circuit_breaker_address, get_non_owner_address());
    circuit_breaker.set_api_key_hash(new_api_key_hash);
}

#[test]
#[should_panic(expected: ('Not owner',))]
fn test_only_vault_owner_can_set_circuit_breaker() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let (mock_vault, mock_vault_address) = deploy_mock_vault();
    
    start_cheat_caller_address(mock_vault_address, get_non_owner_address());
    mock_vault.set_circuit_breaker(circuit_breaker_address);
}

#[test]
fn test_integrated_system_normal_operation() {
    let (circuit_breaker, mock_vault, circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let user_address = get_user_address();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.deposit(DEPOSIT_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.withdraw(200);
    stop_cheat_caller_address(mock_vault_address);
    
    let balance_after_withdraw = mock_vault.get_balance(user_address);
    assert(balance_after_withdraw == DEPOSIT_AMOUNT - 200, 'Normal withdraw failed');
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused, 'Should not be paused');
}

#[test]
#[should_panic(expected: ('Function is paused ',))]
fn test_withdraw_fails_when_paused() {
    let (circuit_breaker, mock_vault, circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let user_address = get_user_address();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.deposit(DEPOSIT_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.withdraw(WITHDRAW_AMOUNT);
}

#[test]
fn test_emergency_withdraw_bypasses_circuit_breaker() {
    let (circuit_breaker, mock_vault, circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let user_address = get_user_address();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.deposit(DEPOSIT_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(is_paused, 'Function should be paused');
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.emergency_withdraw(WITHDRAW_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    let final_balance = mock_vault.get_balance(user_address);
    let expected_balance = DEPOSIT_AMOUNT - WITHDRAW_AMOUNT;
    assert(final_balance == expected_balance, 'Emergency withdraw failed');
}


#[test]
fn test_ownership_transfer() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let new_owner = get_non_owner_address();
    
    let initial_owner = circuit_breaker.get_owner();
    assert(initial_owner == get_owner_address(), 'Initial owner wrong');
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.transfer_ownership(new_owner);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let owner = circuit_breaker.get_owner();
    assert(owner == new_owner, 'Ownership transfer failed');
}

#[test]
fn test_api_key_hash_update() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let new_api_key_hash: felt252 = 'new_api_key';
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.set_api_key_hash(new_api_key_hash);
    stop_cheat_caller_address(circuit_breaker_address);
    
}

#[test]
fn test_check_and_trip_with_trip_status() {
    let (circuit_breaker, _mock_vault, _circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let function_selector = starknet::selector!("withdraw");
    
    let api_response: ByteArray = "TRIP";  // Simplified to just "TRIP"
    let signature = create_api_signature(@api_response);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused, 'Should not be paused initially');
    
    circuit_breaker.check_and_trip(mock_vault_address, function_selector, api_response, signature);
    
    let is_paused_after = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(is_paused_after, 'Should be paused after trip');
}

#[test]
fn test_check_and_trip_with_safe_status() {
    let (circuit_breaker, _mock_vault, _circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let function_selector = starknet::selector!("withdraw");
    
    let api_response: ByteArray = "SAFE";  
    let signature = create_api_signature(@api_response);
    
    circuit_breaker.check_and_trip(mock_vault_address, function_selector, api_response, signature);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused, 'Should not be paused for SAFE');
}


#[test]
fn test_multiple_functions_pause_independently() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let mock_vault_address = contract_address_const::<'vault'>();
    let withdraw_selector = starknet::selector!("withdraw");
    let deposit_selector = starknet::selector!("deposit");
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, withdraw_selector);
    circuit_breaker.pause(mock_vault_address, deposit_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_withdraw_paused = circuit_breaker.is_paused(mock_vault_address, withdraw_selector);
    let is_deposit_paused = circuit_breaker.is_paused(mock_vault_address, deposit_selector);
    
    assert(is_withdraw_paused, 'Withdraw should be paused');
    assert(is_deposit_paused, 'Deposit should be paused');
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.resume(mock_vault_address, withdraw_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_withdraw_paused_after = circuit_breaker.is_paused(mock_vault_address, withdraw_selector);
    let is_deposit_paused_after = circuit_breaker.is_paused(mock_vault_address, deposit_selector);
    
    assert(!is_withdraw_paused_after, 'Withdraw should be resumed');
    assert(is_deposit_paused_after, 'Deposit should still be paused');
}


#[test]
fn test_pause_resume_with_timestamps() {
    let (circuit_breaker, circuit_breaker_address) = deploy_circuit_breaker();
    let mock_vault_address = contract_address_const::<'vault'>();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_block_timestamp(circuit_breaker_address, 1000);
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.resume(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    stop_cheat_block_timestamp(circuit_breaker_address);
}


#[test]
fn test_complete_market_emergency_scenario() {
    let (circuit_breaker, mock_vault, circuit_breaker_address, mock_vault_address) = setup_complete_system();
    let user_address = get_user_address();
    let function_selector = starknet::selector!("withdraw");
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.deposit(DEPOSIT_AMOUNT);
    stop_cheat_caller_address(mock_vault_address);
    
    let initial_balance = mock_vault.get_balance(user_address);
    assert(initial_balance == DEPOSIT_AMOUNT, 'Initial deposit failed');
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.withdraw(200);
    stop_cheat_caller_address(mock_vault_address);
    
    let balance_after_normal_withdraw = mock_vault.get_balance(user_address);
    assert(balance_after_normal_withdraw == DEPOSIT_AMOUNT - 200, 'Normal withdraw failed');
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.pause(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_paused = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(is_paused, 'Function should be paused');
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.emergency_withdraw(300);
    stop_cheat_caller_address(mock_vault_address);
    
    let balance_after_emergency = mock_vault.get_balance(user_address);
    assert(balance_after_emergency == DEPOSIT_AMOUNT - 200 - 300, 'Emergency withdraw failed');
    
    start_cheat_caller_address(circuit_breaker_address, get_owner_address());
    circuit_breaker.resume(mock_vault_address, function_selector);
    stop_cheat_caller_address(circuit_breaker_address);
    
    let is_paused_after_resume = circuit_breaker.is_paused(mock_vault_address, function_selector);
    assert(!is_paused_after_resume, 'Function should be resumed');
    
    start_cheat_caller_address(mock_vault_address, user_address);
    mock_vault.withdraw(100);
    stop_cheat_caller_address(mock_vault_address);
    
    let final_balance = mock_vault.get_balance(user_address);
    let expected_final = DEPOSIT_AMOUNT - 200 - 300 - 100;
    assert(final_balance == expected_final, 'Final withdraw failed');
    
    let total_deposits = mock_vault.get_total_deposits();
    assert(total_deposits == final_balance, 'Total deposits inconsistent');
}