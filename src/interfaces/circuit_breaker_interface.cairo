use starknet::ContractAddress;
use crate::types::structs::SignedU256;

#[starknet::interface]
pub trait ICircuitBreaker<TContractState> {
    fn register_asset(
        ref self: TContractState,
        asset: ContractAddress,
        metric_threshold: u256,
        min_amount_to_limit: u256
    );

    fn update_asset_params(
        ref self: TContractState,
        asset: ContractAddress,
        metric_threshold: u256,
        min_amount_to_limit: u256
    );

    // Token flow tracking
    fn on_token_inflow(ref self: TContractState, token: ContractAddress, amount: u256);

    fn on_token_outflow(
        ref self: TContractState,
        token: ContractAddress,
        amount: u256,
        recipient: ContractAddress,
        revert_on_rate_limit: bool
    );

    fn on_native_asset_inflow(ref self: TContractState, amount: u256);

    fn on_native_asset_outflow(
        ref self: TContractState,
        recipient: ContractAddress,
        revert_on_rate_limit: bool
    ) -> bool;

    // Locked fund management
    // fn claim_locked_funds(ref self: TContractState, asset: ContractAddress, recipient: ContractAddress);

    // Admin functions
    fn set_admin(ref self: TContractState, new_admin: ContractAddress);
    fn override_rate_limit(ref self: TContractState, asset : ContractAddress, max_payouts : u32);
    fn override_expired_rate_limit(ref self: TContractState);
    fn add_protected_contracts(ref self: TContractState, protected_contracts: Array<ContractAddress>);
    fn remove_protected_contracts(ref self: TContractState, protected_contracts: Array<ContractAddress>);
    fn start_grace_period(ref self: TContractState, grace_period_end_timestamp: u64);
    fn mark_as_not_operational(ref self: TContractState);
    fn mark_unpause_operational(ref self: TContractState);
    fn migrate_funds_after_exploit(
        ref self: TContractState,
        assets: Array<ContractAddress>,
        recovery_recipient: ContractAddress
    );

    // Utility functions
    fn clear_backlog(ref self: TContractState, token: ContractAddress, max_iterations: u256);

    // View functions
    fn locked_funds(self: @TContractState, recipient: ContractAddress, asset: ContractAddress) -> u256;
    fn is_protected_contract(self: @TContractState, account: ContractAddress) -> bool;
    fn admin(self: @TContractState) -> ContractAddress;
    fn is_rate_limited(self: @TContractState) -> bool;
    fn rate_limit_cooldown_period(self: @TContractState) -> u64;
    fn last_rate_limit_timestamp(self: @TContractState) -> u64;
    fn grace_period_end_timestamp(self: @TContractState) -> u64;
    fn is_rate_limit_triggered(self: @TContractState, asset: ContractAddress) -> bool;
    fn is_in_grace_period(self: @TContractState) -> bool;
    fn is_operational(self: @TContractState) -> bool;
    fn token_liquidity_changes(
        self: @TContractState,
        token: ContractAddress,
        tick_timestamp: u64
    ) -> (u64, SignedU256);
    fn withdrawal_period(self: @TContractState) -> u64;
    fn tick_length(self: @TContractState) -> u64;
    fn native_address_proxy(self: @TContractState) -> ContractAddress;

    // Guardian management functions
    fn add_guardian(ref self: TContractState, guardian: ContractAddress);
    fn remove_guardian(ref self: TContractState, guardian: ContractAddress);
    fn is_guardian(self: @TContractState, address: ContractAddress) -> bool;
    fn guardian_count(self: @TContractState) -> u32;
    
    // Advanced guardian functions
    fn guardian_emergency_pause(ref self: TContractState);
    fn guardian_propose_rate_limit_override(ref self: TContractState, proposal_id: u256);
    fn guardian_vote_rate_limit_override(ref self: TContractState, proposal_id: u256, approve: bool);
    fn execute_guardian_rate_limit_override(ref self: TContractState, proposal_id: u256, asset: ContractAddress, max_payouts: u32);
    fn set_guardian_threshold(ref self: TContractState, new_threshold: u32);
    
    // Guardian monitoring functions
    fn get_guardian_override_proposal(self: @TContractState, proposal_id: u256) -> (ContractAddress, u32, u32, u64, bool);
    fn guardian_threshold(self: @TContractState) -> u32;
    fn has_guardian_voted(self: @TContractState, proposal_id: u256, guardian: ContractAddress) -> bool;
}