use starknet::{ContractAddress};
use openzeppelin_access::ownable::OwnableComponent;
use openzeppelin_security::pausable::PausableComponent;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

#[derive(Drop, starknet::Event)]
    pub struct AssetRegistered {
        #[key]
        pub asset: ContractAddress,
        pub metric_threshold: u256,
        pub min_amount_to_limit: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetInflow {
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetRateLimitBreached {
        #[key]
        pub asset: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssetWithdraw {
        #[key]
        pub asset: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
        pub amount: u256,
    }
    

    #[derive(Drop, starknet::Event)]
    pub struct LockedFundsClaimed {
        #[key]
        pub asset: ContractAddress,
        #[key]
        pub recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AdminSet {
        #[key]
        pub new_admin: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GracePeriodStarted {
        pub grace_period_end: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenBacklogCleaned {
        #[key]
        pub token: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GuardianEmergencyPause {
        #[key]
        pub guardian: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GuardianOverrideProposed {
        #[key]
        pub proposal_id: u256,
        #[key]
        pub proposer: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GuardianOverrideVote {
        #[key]
        pub proposal_id: u256,
        #[key]
        pub guardian: ContractAddress,
        pub approve: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GuardianOverrideExecuted {
        #[key]
        pub proposal_id: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GuardianThresholdChanged {
        pub old_threshold: u32,
        pub new_threshold: u32,
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct PendingWithdrawal {
    pub recipient: ContractAddress,
    pub amount: u256,
    pub next_recipient: ContractAddress, // 0 if it's the last one in the list
    }


#[starknet::contract]
pub mod CircuitBreaker {
    use core::panic_with_felt252;
    use core::num::traits::Zero;
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp,
        get_contract_address, contract_address_const
    };
    use starknet::storage::{
        Map, StoragePointerReadAccess, StoragePointerWriteAccess,
        StorageMapReadAccess, StorageMapWriteAccess
    };
    use super::PendingWithdrawal;
    use super::{OwnableComponent, PausableComponent,
        IERC20Dispatcher, IERC20DispatcherTrait, AssetInflow, AssetRegistered, AssetRateLimitBreached, AssetWithdraw, LockedFundsClaimed, TokenBacklogCleaned, GracePeriodStarted, AdminSet, GuardianEmergencyPause, GuardianOverrideProposed, GuardianOverrideVote, GuardianOverrideExecuted, GuardianThresholdChanged};
    use crate::interfaces::circuit_breaker_interface::ICircuitBreaker;
    use crate::types::structs::{Limiter, LiqChangeNode, SignedU256, LimitStatus, SignedU256Trait, GuardianOverrideProposal};
    use crate::utils::limiter_lib::{LimiterLibTrait, LimiterLibImpl, MapTrait, get_tick_timestamp};
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternalTrait;
    use openzeppelin_security::PausableComponent::InternalTrait as PausableInternalTrait;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;


    #[derive(Drop)]
    struct NodeMapWrapper {
        state: @ContractState,
        token: ContractAddress,
    }

    impl NodeMapWrapperImpl of MapTrait<NodeMapWrapper> {
        fn read(ref self: NodeMapWrapper, key: u64) -> LiqChangeNode {
            self.state.list_nodes.read((self.token, key))
        }

        fn write(ref self: NodeMapWrapper, key: u64, value: LiqChangeNode) {
            //Returning just to satisfy the trait
        }
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        guardians: Map<ContractAddress, bool>,
        guardian_count: u32,
        guardian_threshold: u32,
        guardian_override_proposals: Map<u256, GuardianOverrideProposal>,
        guardian_votes: Map<(u256, ContractAddress), bool>, // (proposal_id, guardian) -> has_voted

        token_limiters: Map<ContractAddress, Limiter>,
        locked_funds: Map<(ContractAddress, ContractAddress), u256>, // (recipient, asset) -> amount
        list_nodes: Map<(ContractAddress, u64), LiqChangeNode>, // (token, timestamp) -> node
        is_protected_contract: Map<ContractAddress, bool>,

        admin: ContractAddress,
        is_rate_limited: bool,
        rate_limit_cooldown_period: u64,
        last_rate_limit_timestamp: u64,
        grace_period_end_timestamp: u64,
        withdrawal_period: u64,
        tick_length: u64,

        native_address_proxy: ContractAddress,
        eth_token_address: ContractAddress,

        pending_head: Map<ContractAddress, ContractAddress>, // (asset) -> first recipient
        pending_withdrawals: Map<(ContractAddress, ContractAddress), PendingWithdrawal>, // (asset, recipient) -> withdrawal data
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        AssetRegistered: AssetRegistered,
        AssetInflow: AssetInflow,
        AssetRateLimitBreached: AssetRateLimitBreached,
        AssetWithdraw: AssetWithdraw,
        LockedFundsClaimed: LockedFundsClaimed,
        AdminSet: AdminSet,
        GracePeriodStarted: GracePeriodStarted,
        TokenBacklogCleaned: TokenBacklogCleaned,
        GuardianEmergencyPause: GuardianEmergencyPause,
        GuardianOverrideProposed: GuardianOverrideProposed,
        GuardianOverrideVote: GuardianOverrideVote,
        GuardianOverrideExecuted: GuardianOverrideExecuted,
        GuardianThresholdChanged: GuardianThresholdChanged,
    }


    pub mod Errors {
        pub const NOT_A_PROTECTED_CONTRACT: felt252 = 'Not a protected contract';
        pub const NOT_ADMIN: felt252 = 'Not admin';
        pub const INVALID_ADMIN_ADDRESS: felt252 = 'Invalid admin address';
        pub const NO_LOCKED_FUNDS: felt252 = 'No locked funds';
        pub const RATE_LIMITED: felt252 = 'Rate limited';
        pub const NOT_RATE_LIMITED: felt252 = 'Not rate limited';
        pub const COOLDOWN_PERIOD_NOT_REACHED: felt252 = 'Cooldown period not reached';
        pub const INVALID_GRACE_PERIOD_END: felt252 = 'Invalid grace period end';
        pub const PROTOCOL_WAS_EXPLOITED: felt252 = 'Protocol was exploited';
        pub const NOT_EXPLOITED: felt252 = 'Not exploited';
        pub const NATIVE_TRANSFER_FAILED: felt252 = 'Native transfer failed';
        pub const INVALID_RECIPIENT_ADDRESS: felt252 = 'Invalid recipient address';
        pub const INSUFFICIENT_BALANCE: felt252 = 'Insufficient balance';
        pub const NOT_GUARDIAN: felt252 = 'Not guardian';
        pub const PROPOSAL_NOT_FOUND: felt252 = 'Proposal not found';
        pub const PROPOSAL_ALREADY_EXECUTED: felt252 = 'Proposal already executed';
        pub const ALREADY_VOTED: felt252 = 'Already voted';
        pub const INSUFFICIENT_VOTES: felt252 = 'Insufficient votes';
        pub const INVALID_THRESHOLD: felt252 = 'Invalid threshold';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        rate_limit_cooldown_period: u64,
        withdrawal_period: u64,
        tick_length: u64,
        eth_token_address: ContractAddress
    ) {
        self.admin.write(admin);
        self.ownable.initializer(admin);
        self.guardian_count.write(0);
        self.guardian_threshold.write(1); // Default to requiring 1 guardian for multi-sig operations
        self.rate_limit_cooldown_period.write(rate_limit_cooldown_period);
        self.withdrawal_period.write(withdrawal_period);
        self.tick_length.write(tick_length);
        self.is_rate_limited.write(false);

        self.native_address_proxy.write(contract_address_const::<1>());
        self.eth_token_address.write(eth_token_address);
    }

    #[abi(embed_v0)]
    impl CircuitBreakerImpl of ICircuitBreaker<ContractState> {
        fn register_asset(
            ref self: ContractState,
            asset: ContractAddress,
            metric_threshold: u256,
            min_amount_to_limit: u256
        ) {
            self._assert_only_admin();
            let mut limiter = self.token_limiters.read(asset);
            LimiterLibImpl::init(ref limiter, metric_threshold, min_amount_to_limit);
            self.token_limiters.write(asset, limiter);
            self.emit(Event::AssetRegistered(AssetRegistered {
                asset,
                metric_threshold,
                min_amount_to_limit
            }));
        }

        fn update_asset_params(
            ref self: ContractState,
            asset: ContractAddress,
            metric_threshold: u256,
            min_amount_to_limit: u256
        ) {
            self._assert_only_admin();
            let mut limiter = self.token_limiters.read(asset);
            LimiterLibImpl::update_params(ref limiter, metric_threshold, min_amount_to_limit);
            
            // Sync the limiter
            self._sync_limiter_with_lib(asset, 0xffffffffffffffffffffffffffffffff);
        }

        fn on_token_inflow(ref self: ContractState, token: ContractAddress, amount: u256) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            self._on_token_inflow(token, amount);
        }

        fn on_token_outflow(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            self._on_token_outflow(token, amount, recipient, revert_on_rate_limit);
        }

        fn on_native_asset_inflow(ref self: ContractState, amount: u256) {
            self._assert_only_protected();
            self.pausable.assert_not_paused();
            let native_proxy = self.native_address_proxy.read();
            self._on_token_inflow(native_proxy, amount);
        }

        fn on_native_asset_outflow(
            ref self: ContractState,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) -> bool {
            self._assert_only_protected();
            self.pausable.assert_not_paused();

            let native_proxy = self.native_address_proxy.read();
            let amount: u256 = 0; 

            self._on_token_outflow(native_proxy, amount, recipient, revert_on_rate_limit);
            true
        }

        // fn claim_locked_funds(ref self: ContractState, asset: ContractAddress, recipient: ContractAddress) {
        //     self.pausable.assert_not_paused();
        //     let amount = self.locked_funds.read((recipient, asset));
        //     assert(amount > 0, Errors::NO_LOCKED_FUNDS);
        //     assert(!self.is_rate_limited.read(), Errors::RATE_LIMITED);

        //     self.locked_funds.write((recipient, asset), 0);

        //     self.emit(Event::LockedFundsClaimed(LockedFundsClaimed { asset, recipient }));
        //     self._safe_transfer_including_native(asset, recipient, amount);
        // }

        fn clear_backlog(ref self: ContractState, token: ContractAddress, max_iterations: u256) {
            self._sync_limiter_with_lib(token, max_iterations);
            self.emit(Event::TokenBacklogCleaned(TokenBacklogCleaned {
                token,
                timestamp: get_block_timestamp(),
            }));
        }

        fn override_expired_rate_limit(ref self: ContractState) {
            assert(self.is_rate_limited.read(), Errors::NOT_RATE_LIMITED);
            let cooldown_period = self.rate_limit_cooldown_period.read();
            let last_limit_time = self.last_rate_limit_timestamp.read();

            assert(
                get_block_timestamp() - last_limit_time >= cooldown_period,
                Errors::COOLDOWN_PERIOD_NOT_REACHED
            );
            self.is_rate_limited.write(false);
        }

        fn set_admin(ref self: ContractState, new_admin: ContractAddress) {
            self._assert_only_admin();
            assert(!new_admin.is_zero(), Errors::INVALID_ADMIN_ADDRESS);

            self.admin.write(new_admin);
            self.ownable._transfer_ownership(new_admin);
            self.emit(Event::AdminSet(AdminSet { new_admin }));
        }

        fn override_rate_limit(ref self: ContractState,asset: ContractAddress, max_payouts: u32) {
            self._assert_only_admin();
            assert(self.is_rate_limited.read(), Errors::NOT_RATE_LIMITED);

            let mut current_recipient = self.pending_head.read(asset);
            let mut payouts_processed: u32 = 0;

            // Iterate through the linked list and pay out locked funds
            loop {
                if current_recipient.is_zero() || payouts_processed >= max_payouts {
                    break;
                }

                let withdrawal = self.pending_withdrawals.read((asset, current_recipient));
                let amount_to_pay = withdrawal.amount;

                if amount_to_pay > 0 {
                    // Clear the user's locked funds record first
                    self.locked_funds.write((current_recipient, asset), 0);
                    // Pay the user
                    self._safe_transfer_including_native(asset, current_recipient, amount_to_pay);
                }

                // Move to the next user in the queue
                let next_recipient = withdrawal.next_recipient;
                // Clean up the processed node from storage
                self.pending_withdrawals.write((asset, current_recipient), PendingWithdrawal {
                    recipient: contract_address_const::<0>(),
                    amount: 0,
                    next_recipient: contract_address_const::<0>(),
                });
                current_recipient = next_recipient;
                payouts_processed += 1;
            }
            self.pending_head.write(asset, current_recipient);

            // Only fully reset the rate limit if the entire queue has been cleared
            if current_recipient.is_zero() {
                self.is_rate_limited.write(false);
            }
        }

        fn add_protected_contracts(ref self: ContractState, protected_contracts: Array<ContractAddress>) {
            self._assert_only_admin();
            let mut i = 0;
            while i < protected_contracts.len() {
                self.is_protected_contract.write(*protected_contracts.at(i), true);
                i += 1;
            }
        }

        fn remove_protected_contracts(ref self: ContractState, protected_contracts: Array<ContractAddress>) {
            self._assert_only_admin();
            let mut i = 0;
            while i < protected_contracts.len() {
                self.is_protected_contract.write(*protected_contracts.at(i), false);
                i += 1;
            }
        }

        fn start_grace_period(ref self: ContractState, grace_period_end_timestamp: u64) {
            self._assert_only_admin();
            assert(grace_period_end_timestamp > get_block_timestamp(), Errors::INVALID_GRACE_PERIOD_END);

            self.grace_period_end_timestamp.write(grace_period_end_timestamp);
            self.emit(Event::GracePeriodStarted(GracePeriodStarted { grace_period_end: grace_period_end_timestamp }));
        }

        fn mark_as_not_operational(ref self: ContractState) {
            self._assert_only_admin();
            self.pausable.pause();
        }

        fn mark_unpause_operational(ref self : ContractState) {
            self._assert_only_admin();
            self.pausable.unpause();
        }

        fn migrate_funds_after_exploit(
            ref self: ContractState,
            assets: Array<ContractAddress>,
            recovery_recipient: ContractAddress
        ) {
            self._assert_only_admin();
            assert(self.pausable.is_paused(), Errors::NOT_EXPLOITED);

            let mut i = 0;
            while i < assets.len() {
                let asset = *assets.at(i);
                let native_proxy = self.native_address_proxy.read();

                let amount = if asset == native_proxy {
                    let eth_token_address = self.eth_token_address.read();
                    let eth_contract = IERC20Dispatcher { contract_address: eth_token_address };
                    eth_contract.balance_of(get_contract_address())
                } else {
                    let token = IERC20Dispatcher { contract_address: asset };
                    token.balance_of(get_contract_address())
                };

                if amount > 0 {
                    self._safe_transfer_including_native(asset, recovery_recipient, amount);
                }
                i += 1;
            }
        }

        // View functions
        fn locked_funds(self: @ContractState, recipient: ContractAddress, asset: ContractAddress) -> u256 {
            self.locked_funds.read((recipient, asset))
        }

        fn is_protected_contract(self: @ContractState, account: ContractAddress) -> bool {
            self.is_protected_contract.read(account)
        }

        fn admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn is_rate_limited(self: @ContractState) -> bool {
            self.is_rate_limited.read()
        }

        fn rate_limit_cooldown_period(self: @ContractState) -> u64 {
            self.rate_limit_cooldown_period.read()
        }

        fn last_rate_limit_timestamp(self: @ContractState) -> u64 {
            self.last_rate_limit_timestamp.read()
        }

        fn grace_period_end_timestamp(self: @ContractState) -> u64 {
            self.grace_period_end_timestamp.read()
        }

        fn is_rate_limit_triggered(self: @ContractState, asset: ContractAddress) -> bool {
            let limiter = self.token_limiters.read(asset);
            LimiterLibImpl::status(@limiter) == LimitStatus::Triggered
        }

        fn is_in_grace_period(self: @ContractState) -> bool {
            get_block_timestamp() <= self.grace_period_end_timestamp.read()
        }

        fn is_operational(self: @ContractState) -> bool {
            !self.pausable.is_paused()
        }

        fn token_liquidity_changes(
            self: @ContractState,
            token: ContractAddress,
            tick_timestamp: u64
        ) -> (u64, SignedU256) {
            let node = self.list_nodes.read((token, tick_timestamp));
            (node.next_timestamp, node.amount)
        }

        fn withdrawal_period(self: @ContractState) -> u64 {
            self.withdrawal_period.read()
        }

        fn tick_length(self: @ContractState) -> u64 {
            self.tick_length.read()
        }

        fn native_address_proxy(self: @ContractState) -> ContractAddress {
            self.native_address_proxy.read()
        }

        // Guardian functions
        fn add_guardian(ref self: ContractState, guardian: ContractAddress) {
            self._assert_only_admin();
            assert(!guardian.is_zero(), 'Invalid guardian address');
            assert(!self.guardians.read(guardian), 'Guardian already exists');
            
            self.guardians.write(guardian, true);
            let count = self.guardian_count.read();
            self.guardian_count.write(count + 1);
        }

        fn remove_guardian(ref self: ContractState, guardian: ContractAddress) {
            self._assert_only_admin();
            assert(self.guardians.read(guardian), 'Guardian not found');
            
            self.guardians.write(guardian, false);
            let count = self.guardian_count.read();
            if count > 0 {
                self.guardian_count.write(count - 1);
            }
        }

        fn is_guardian(self: @ContractState, address: ContractAddress) -> bool {
            self.guardians.read(address)
        }

        fn guardian_count(self: @ContractState) -> u32 {
            self.guardian_count.read()
        }

        // ==================== ADVANCED GUARDIAN FUNCTIONS ====================

        fn guardian_emergency_pause(ref self: ContractState) {
            let caller = get_caller_address();
            assert(self.guardians.read(caller), Errors::NOT_GUARDIAN);
            
            // Only allow if system is operational
            assert(!self.pausable.is_paused(), 'Already paused');
            
            // Emergency pause by guardian
            self.pausable.pause();
            
            self.emit(Event::GuardianEmergencyPause(GuardianEmergencyPause {
                guardian: caller,
                timestamp: get_block_timestamp(),
            }));
        }

        fn guardian_propose_rate_limit_override(ref self: ContractState, proposal_id: u256) {
            let caller = get_caller_address();
            assert(self.guardians.read(caller), Errors::NOT_GUARDIAN);
            assert(self.is_rate_limited.read(), Errors::NOT_RATE_LIMITED);
            
            // Check proposal doesn't already exist
            let existing_proposal = self.guardian_override_proposals.read(proposal_id);
            assert(existing_proposal.proposer.is_zero(), 'Proposal already exists');
            
            // Create new proposal
            let proposal = GuardianOverrideProposal {
                proposer: caller,
                votes_for: 1, // Proposer automatically votes for
                votes_against: 0,
                creation_timestamp: get_block_timestamp(),
                executed: false,
            };
            
            self.guardian_override_proposals.write(proposal_id, proposal);
            self.guardian_votes.write((proposal_id, caller), true);
            
            self.emit(Event::GuardianOverrideProposed(GuardianOverrideProposed {
                proposal_id,
                proposer: caller,
                timestamp: get_block_timestamp(),
            }));
        }

        fn guardian_vote_rate_limit_override(ref self: ContractState, proposal_id: u256, approve: bool) {
            let caller = get_caller_address();
            assert(self.guardians.read(caller), Errors::NOT_GUARDIAN);
            
            // Check proposal exists
            let mut proposal = self.guardian_override_proposals.read(proposal_id);
            assert(!proposal.proposer.is_zero(), Errors::PROPOSAL_NOT_FOUND);
            assert(!proposal.executed, Errors::PROPOSAL_ALREADY_EXECUTED);
            
            // Check guardian hasn't already voted
            assert(!self.guardian_votes.read((proposal_id, caller)), Errors::ALREADY_VOTED);
            
            // Record vote
            self.guardian_votes.write((proposal_id, caller), true);
            
            if approve {
                proposal.votes_for += 1;
            } else {
                proposal.votes_against += 1;
            }
            
            self.guardian_override_proposals.write(proposal_id, proposal);
            
            self.emit(Event::GuardianOverrideVote(GuardianOverrideVote {
                proposal_id,
                guardian: caller,
                approve,
            }));
        }

       fn execute_guardian_rate_limit_override(ref self: ContractState, proposal_id: u256, asset: ContractAddress, max_payouts: u32) {
            // This function now processes the pending withdrawal queue for a specific asset
            // after a successful guardian vote, similar to the admin's override function.

            // 1. Verify the proposal and the caller's authority
            let caller = get_caller_address();
            assert(self.guardians.read(caller), Errors::NOT_GUARDIAN);
            
            let mut proposal = self.guardian_override_proposals.read(proposal_id);
            assert(!proposal.proposer.is_zero(), Errors::PROPOSAL_NOT_FOUND);
            assert(!proposal.executed, Errors::PROPOSAL_ALREADY_EXECUTED);
            
            let threshold = self.guardian_threshold.read();
            assert(proposal.votes_for >= threshold, Errors::INSUFFICIENT_VOTES);
            
            // 2. Mark the proposal as executed to prevent re-use
            proposal.executed = true;
            self.guardian_override_proposals.write(proposal_id, proposal);
            
            // 3. --- NEW LOGIC: Process the pending withdrawal queue ---
            let mut current_recipient = self.pending_head.read(asset);
            let mut payouts_processed: u32 = 0;

            // Iterate through the linked list and pay out locked funds
            loop {
                if current_recipient.is_zero() || payouts_processed >= max_payouts {
                    break;
                }

                let withdrawal = self.pending_withdrawals.read((asset, current_recipient));
                let amount_to_pay = withdrawal.amount;

                if amount_to_pay > 0 {
                    // Clear the user's locked funds record first
                    self.locked_funds.write((current_recipient, asset), 0);
                    // Pay the user
                    self._safe_transfer_including_native(asset, current_recipient, amount_to_pay);
                }

                // Move to the next user in the queue
                let next_recipient = withdrawal.next_recipient;
                // Clean up the processed node from storage
                self.pending_withdrawals.write((asset, current_recipient), PendingWithdrawal {
                    recipient: contract_address_const::<0>(),
                    amount: 0,
                    next_recipient: contract_address_const::<0>(),
                });
                current_recipient = next_recipient;
                payouts_processed += 1;
            }

            // 4. Update the head of the list to the next unprocessed user
            self.pending_head.write(asset, current_recipient);

            // 5. Only fully reset the global rate limit if the entire queue for this asset is clear
            if current_recipient.is_zero() {
                self.is_rate_limited.write(false);
            }
            
            self.emit(Event::GuardianOverrideExecuted(GuardianOverrideExecuted {
                proposal_id,
                timestamp: get_block_timestamp(),
            }));
        }

        fn set_guardian_threshold(ref self: ContractState, new_threshold: u32) {
            self._assert_only_admin();
            let guardian_count = self.guardian_count.read();
            assert(new_threshold > 0 && new_threshold <= guardian_count, Errors::INVALID_THRESHOLD);
            
            let old_threshold = self.guardian_threshold.read();
            self.guardian_threshold.write(new_threshold);
            
            self.emit(Event::GuardianThresholdChanged(GuardianThresholdChanged {
                old_threshold,
                new_threshold,
            }));
        }

        // ==================== GUARDIAN MONITORING FUNCTIONS ====================

        fn get_guardian_override_proposal(self: @ContractState, proposal_id: u256) -> (ContractAddress, u32, u32, u64, bool) {
            let proposal = self.guardian_override_proposals.read(proposal_id);
            (proposal.proposer, proposal.votes_for, proposal.votes_against, proposal.creation_timestamp, proposal.executed)
        }

        fn guardian_threshold(self: @ContractState) -> u32 {
            self.guardian_threshold.read()
        }

        fn has_guardian_voted(self: @ContractState, proposal_id: u256, guardian: ContractAddress) -> bool {
            self.guardian_votes.read((proposal_id, guardian))
        }
    }

    // Storage wrapper for MapTrait implementation
    #[derive(Drop)]
    struct StorageMapWrapper {
        token: ContractAddress,
        state: @ContractState,
    }

    #[derive(Drop)]
    struct MutableStorageMapWrapper {
        token: ContractAddress,
        state: @ContractState,
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_only_protected(self: @ContractState) {
            let caller = get_caller_address();
            assert(self.is_protected_contract.read(caller), Errors::NOT_A_PROTECTED_CONTRACT);
        }

        fn _assert_only_admin(self: @ContractState) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), Errors::NOT_ADMIN);
        }

        // Sync limiter using LimiterLib directly (similar to Solidity)
        fn _sync_limiter_with_lib(ref self: ContractState, token: ContractAddress, max_iterations: u256) {
            let mut limiter = self.token_limiters.read(token);
            let withdrawal_period = self.withdrawal_period.read();
            
            // We need to manually handle the sync since we can't pass mutable storage map
            let mut current_head = limiter.list_head;
            let mut total_change = SignedU256Trait::zero();
            let mut iter: u256 = 0;

            while current_head != 0
                && get_block_timestamp() - current_head >= withdrawal_period
                && iter < max_iterations {

                let node = self.list_nodes.read((token, current_head));
                total_change = total_change.add(node.amount);
                let next_timestamp = node.next_timestamp;

                // Clear data
                self.list_nodes.write((token, current_head), LiqChangeNode {
                    amount: SignedU256Trait::zero(),
                    next_timestamp: 0,
                });
                current_head = next_timestamp;
                iter += 1;
            }

            if current_head == 0 {
                limiter.list_head = 0;
                limiter.list_tail = 0;
            } else {
                limiter.list_head = current_head;
            }

            // When old changes expire from the tracking window:
            // - Remove them from liq_in_period (they're no longer "recent changes")  
            // - liq_total remains unchanged as it represents current actual liquidity
            limiter.liq_in_period = limiter.liq_in_period.sub(total_change);

            self.token_limiters.write(token, limiter);
        }

        fn _record_change_with_lib(ref self: ContractState, token: ContractAddress, amount: SignedU256) {
            let mut limiter = self.token_limiters.read(token);
            if !limiter.initialized {
                return;
            }

            // Skip zero amounts to avoid unnecessary tracking
            if amount.value == 0 {
                return;
            }

            let withdrawal_period = self.withdrawal_period.read();
            let tick_length = self.tick_length.read();
            let current_tick_timestamp = get_tick_timestamp(get_block_timestamp(), tick_length);

            // Sync if needed
            let list_head = limiter.list_head;
            if list_head != 0 && get_block_timestamp() - list_head >= withdrawal_period {
                self._sync_limiter_with_lib(token, 0xffffffffffffffffffffffffffffffff);
                limiter = self.token_limiters.read(token); // Re-read after sync
            }

            // Update liq_in_period for withdrawal period tracking
            limiter.liq_in_period = limiter.liq_in_period.add(amount);
            
            // For liq_total, we track actual current liquidity
            // Deposits increase it, withdrawals decrease it
            limiter.liq_total = limiter.liq_total.add(amount);

            // Update linked list
            if limiter.list_head == 0 {
                limiter.list_head = current_tick_timestamp;
                limiter.list_tail = current_tick_timestamp;
                self.list_nodes.write((token, current_tick_timestamp), LiqChangeNode {
                    amount: amount,
                    next_timestamp: 0,
                });
            } else {
                let list_tail = limiter.list_tail;
                if list_tail == current_tick_timestamp {
                    let mut current_node = self.list_nodes.read((token, current_tick_timestamp));
                    current_node.amount = current_node.amount.add(amount);
                    self.list_nodes.write((token, current_tick_timestamp), current_node);
                } else {
                    let mut tail_node = self.list_nodes.read((token, list_tail));
                    tail_node.next_timestamp = current_tick_timestamp;
                    self.list_nodes.write((token, list_tail), tail_node);

                    self.list_nodes.write((token, current_tick_timestamp), LiqChangeNode {
                        amount: amount,
                        next_timestamp: 0,
                    });
                    limiter.list_tail = current_tick_timestamp;
                }
            }

            self.token_limiters.write(token, limiter);
        }

        fn _on_token_inflow(ref self: ContractState, token: ContractAddress, amount: u256) {
            // Convert to signed positive amount (similar to Solidity int256(_amount))
            let signed_amount = SignedU256Trait::from_u256(amount);
            self._record_change_with_lib(token, signed_amount);
            
            self.emit(Event::AssetInflow(AssetInflow { token, amount }));
        }

        fn _on_token_outflow(
            ref self: ContractState,
            token: ContractAddress,
            amount: u256,
            recipient: ContractAddress,
            revert_on_rate_limit: bool
        ) {
            // Handle zero withdrawal - no need to track or check limits
            if amount == 0 {
                return;
            }

            let mut limiter = self.token_limiters.read(token);
            
            // Check if the token has an enforced rate limit
            if !LimiterLibImpl::initialized(@limiter) {
                // If not rate limited, just transfer the tokens
                self._safe_transfer_including_native(token, recipient, amount);
                return;
            }

            // Record the withdrawal (negative amount)
            let signed_amount = SignedU256Trait::new(amount, true); // true for negative
            self._record_change_with_lib(token, signed_amount);

            // Re-read limiter after recording change
            limiter = self.token_limiters.read(token);

            // Check if the global rate limit is active OR if this transaction triggers a new one
            let mut should_lock_funds = self.is_rate_limited.read();
            if !should_lock_funds && LimiterLibImpl::status(@limiter) == LimitStatus::Triggered && !self._is_in_grace_period() {
                should_lock_funds = true;
                self.is_rate_limited.write(true);
                self.last_rate_limit_timestamp.write(get_block_timestamp());
                self.emit(Event::AssetRateLimitBreached(AssetRateLimitBreached {
                    asset: token,
                    timestamp: get_block_timestamp(),
                }));
            }
            
            if should_lock_funds {
                if revert_on_rate_limit {
                    panic_with_felt252(Errors::RATE_LIMITED);
                }
                                let current_locked = self.locked_funds.read((recipient, token));
                let new_locked_amount = current_locked + amount;
                self.locked_funds.write((recipient, token), new_locked_amount);
                let existing_withdrawal = self.pending_withdrawals.read((token, recipient));
                if existing_withdrawal.recipient.is_zero() {
                    let head = self.pending_head.read(token);
                    if head.is_zero() {
                        self.pending_head.write(token, recipient);
                    } else {
                        
                        let mut current_recipient_in_list = head;
                        loop {
                            let mut node = self.pending_withdrawals.read((token, current_recipient_in_list));
                            if node.next_recipient.is_zero() {
                                node.next_recipient = recipient;
                                self.pending_withdrawals.write((token, current_recipient_in_list), node);
                                break;
                            }
                            current_recipient_in_list = node.next_recipient;
                        };
                    }
                }
                
                // 3. Create or update the node for the current recipient with their total locked amount.
                self.pending_withdrawals.write((token, recipient), PendingWithdrawal {
                    recipient: recipient,
                    amount: new_locked_amount, // Store the *total* amount they have locked.
                    next_recipient: contract_address_const::<0>(), 
                });

                return;
            }

            // If everything is good, transfer the tokens
            self._safe_transfer_including_native(token, recipient, amount);
            self.emit(Event::AssetWithdraw(AssetWithdraw { asset: token, recipient, amount }));
        }

        fn _safe_transfer_including_native(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            if amount == 0 {
                return;
            }

            let native_proxy = self.native_address_proxy.read();
            if token == native_proxy {
                let eth_token_address = self.eth_token_address.read();
                self._transfer_native(recipient, amount, eth_token_address);
            } else {
                let erc20 = IERC20Dispatcher { contract_address: token };
                let success = erc20.transfer(recipient, amount);
                assert(success, Errors::NATIVE_TRANSFER_FAILED);
            }
        }

        fn _transfer_native(ref self: ContractState, recipient: ContractAddress, amount: u256, eth_token_address: ContractAddress) {
            assert(!recipient.is_zero(), Errors::INVALID_RECIPIENT_ADDRESS);
            
            if amount == 0 {
                return;
            }
            let eth_contract = IERC20Dispatcher { 
                contract_address: eth_token_address
            };
            
            let success = eth_contract.transfer(recipient, amount);
            assert(success, Errors::NATIVE_TRANSFER_FAILED);
        }

        fn _is_in_grace_period(self: @ContractState) -> bool {
            get_block_timestamp() <= self.grace_period_end_timestamp.read()
        }
    }
}