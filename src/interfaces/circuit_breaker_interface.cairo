#[starknet::interface]
pub trait ICircuitBreaker<TContractState> {
   
    fn pause(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252);
    fn resume(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252);
    fn is_paused(self: @TContractState, target_contract: starknet::ContractAddress, function_selector: felt252) -> bool;
    
    fn check_and_trip(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252, api_response: ByteArray, signature: Array<felt252>);
   
    fn set_api_key_hash(ref self: TContractState, new_api_key_hash: felt252);
    fn get_owner(self: @TContractState) -> starknet::ContractAddress;
    fn transfer_ownership(ref self: TContractState, new_owner: starknet::ContractAddress);
}

#[starknet::interface]
pub trait ICircuitBreakerEvents<TContractState> {
    fn emit_paused(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252, timestamp: u64);
    fn emit_resumed(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252, timestamp: u64);
    fn emit_trip_triggered(ref self: TContractState, target_contract: starknet::ContractAddress, function_selector: felt252, timestamp: u64);
}