#[cfg(test)]
mod tests {
    use starknet::{ContractAddress, contract_address_const};
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait,
        start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_timestamp, stop_cheat_block_timestamp,
    };
    
    use circuit_breaker::interfaces::circuit_breaker_interface::{
        ICircuitBreakerDispatcher, ICircuitBreakerDispatcherTrait
    };
    use circuit_breaker::mocks::mock_token::{
        IMockTokenDispatcher, IMockTokenDispatcherTrait
    };
    use circuit_breaker::mocks::mock_defi_protocol::{
        IMockDeFiProtocolDispatcher, IMockDeFiProtocolDispatcherTrait
    };
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_security::interface::{IPausableDispatcher, IPausableDispatcherTrait};

    #[derive(Drop, Copy)]
    struct MockTokenDispatchers {
        mock: IMockTokenDispatcher,
        erc20: IERC20Dispatcher,
        contract_address: ContractAddress,
    }

    fn deploy_circuit_breaker() -> ICircuitBreakerDispatcher {
        let admin = contract_address_const::<'admin'>();
        let rate_limit_cooldown_period: u64 = 259200; // 3 days
        let withdrawal_period: u64 = 14400; // 4 hours
        let tick_length: u64 = 300; // 5 minutes
        let eth_token_address = contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>();
        
        let circuit_breaker_class = declare("CircuitBreaker").unwrap().contract_class();
        let (contract_address, _) = circuit_breaker_class.deploy(
            @array![
                admin.into(),
                rate_limit_cooldown_period.into(),
                withdrawal_period.into(),
                tick_length.into(),
                eth_token_address.into()
            ]
        ).unwrap();
        
        ICircuitBreakerDispatcher { contract_address }
    }
    
    fn deploy_mock_token() -> MockTokenDispatchers {
        let contract = declare("MockToken").unwrap().contract_class();
        
        let name: ByteArray = "Mock Token";
        let symbol: ByteArray = "MTK";

        let mut constructor_calldata = array![];
        name.serialize(ref constructor_calldata);
        symbol.serialize(ref constructor_calldata);

        let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
        
        MockTokenDispatchers {
            mock: IMockTokenDispatcher { contract_address },
            erc20: IERC20Dispatcher { contract_address },
            contract_address
        }
    }
    
    fn deploy_mock_defi(circuit_breaker: ContractAddress) -> IMockDeFiProtocolDispatcher {
        let contract = declare("MockDeFiProtocol").unwrap().contract_class();
        let (contract_address, _) = contract.deploy(
            @array![circuit_breaker.into()]
        ).unwrap();
        
        IMockDeFiProtocolDispatcher { contract_address }
    }

    // ==================== GUARDIAN EMERGENCY PAUSE TESTS ====================

    #[test]
    fn test_guardian_emergency_pause() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian = contract_address_const::<'guardian'>();

        // Setup guardian
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Guardian triggers emergency pause
        start_cheat_caller_address(circuit_breaker.contract_address, guardian);
        circuit_breaker.guardian_emergency_pause();
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Verify system is paused
        let pausable = IPausableDispatcher { contract_address: circuit_breaker.contract_address };
        assert_eq!(pausable.is_paused(), true);
    }

    #[test]
    #[should_panic(expected: ('Not guardian',))]
    fn test_guardian_emergency_pause_unauthorized() {
        let circuit_breaker = deploy_circuit_breaker();
        let unauthorized = contract_address_const::<'unauthorized'>();

        // Non-guardian tries to trigger emergency pause
        start_cheat_caller_address(circuit_breaker.contract_address, unauthorized);
        circuit_breaker.guardian_emergency_pause();
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    // ==================== GUARDIAN RATE LIMIT OVERRIDE TESTS ====================

    #[test]
    fn test_guardian_propose_and_execute_override() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup guardians and assets
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        circuit_breaker.set_guardian_threshold(2); // Require 2 guardians for multi-sig
        
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Setup funds and trigger rate limit
        let amount: u256 = 10000000000000000000000; // 10,000 tokens
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 6000000000000000000000); // Trigger rate limit
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);

        // Verify rate limit is active
        assert_eq!(circuit_breaker.is_rate_limited(), true);

        // Guardian 1 proposes override
        let proposal_id: u256 = 1;
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.guardian_propose_rate_limit_override(proposal_id);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Check proposal state
        let (proposer, votes_for, votes_against, timestamp, executed) = circuit_breaker.get_guardian_override_proposal(proposal_id);
        assert_eq!(proposer, guardian1);
        assert_eq!(votes_for, 1);
        assert_eq!(votes_against, 0);
        assert_eq!(executed, false);

        // Guardian 2 votes for the proposal
        start_cheat_caller_address(circuit_breaker.contract_address, guardian2);
        circuit_breaker.guardian_vote_rate_limit_override(proposal_id, true);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Check updated proposal state
        let (_, votes_for, votes_against, _, executed) = circuit_breaker.get_guardian_override_proposal(proposal_id);
        assert_eq!(votes_for, 2);
        assert_eq!(votes_against, 0);
        assert_eq!(executed, false);

        // Execute the override (threshold of 2 is met)
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.execute_guardian_rate_limit_override(proposal_id, token.contract_address, 2);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Verify rate limit is cleared
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        
        // Check proposal is marked as executed
        let (_, _, _, _, executed) = circuit_breaker.get_guardian_override_proposal(proposal_id);
        assert_eq!(executed, true);
    }

    #[test]
    fn test_guardian_override_with_mixed_votes() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();
        let guardian3 = contract_address_const::<'guardian3'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup 3 guardians with threshold of 2
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        circuit_breaker.add_guardian(guardian3);
        circuit_breaker.set_guardian_threshold(2);
        
        circuit_breaker.register_asset(token.contract_address, 7000, 1000000000000000000000);
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Trigger rate limit
        let amount: u256 = 10000000000000000000000;
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 6000000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);

        assert_eq!(circuit_breaker.is_rate_limited(), true);

        // Guardian 1 proposes override
        let proposal_id: u256 = 1;
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.guardian_propose_rate_limit_override(proposal_id);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Guardian 2 votes against
        start_cheat_caller_address(circuit_breaker.contract_address, guardian2);
        circuit_breaker.guardian_vote_rate_limit_override(proposal_id, false);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Guardian 3 votes for  
        start_cheat_caller_address(circuit_breaker.contract_address, guardian3);
        circuit_breaker.guardian_vote_rate_limit_override(proposal_id, true);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Check final vote tally: 2 for (guardian1 + guardian3), 1 against (guardian2)
        let (_, votes_for, votes_against, _, _) = circuit_breaker.get_guardian_override_proposal(proposal_id);
        assert_eq!(votes_for, 2);
        assert_eq!(votes_against, 1);

        // Should be able to execute since votes_for (2) >= threshold (2)
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.execute_guardian_rate_limit_override(proposal_id, token.contract_address, 2);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        assert_eq!(circuit_breaker.is_rate_limited(), false);
    }

    // ==================== GUARDIAN THRESHOLD TESTS ====================

    #[test]
    fn test_set_guardian_threshold() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();
        let guardian3 = contract_address_const::<'guardian3'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add guardians
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        circuit_breaker.add_guardian(guardian3);
        
        // Test different threshold values
        circuit_breaker.set_guardian_threshold(1);
        assert_eq!(circuit_breaker.guardian_threshold(), 1);
        
        circuit_breaker.set_guardian_threshold(2);
        assert_eq!(circuit_breaker.guardian_threshold(), 2);
        
        circuit_breaker.set_guardian_threshold(3);
        assert_eq!(circuit_breaker.guardian_threshold(), 3);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid threshold',))]
    fn test_set_guardian_threshold_too_high() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add only one guardian
        circuit_breaker.add_guardian(guardian1);
        
        // Try to set threshold higher than guardian count
        circuit_breaker.set_guardian_threshold(2); // Should fail
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid threshold',))]
    fn test_set_guardian_threshold_zero() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.set_guardian_threshold(0); // Should fail
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    // ==================== GUARDIAN MONITORING TESTS ====================

    #[test]
    fn test_has_guardian_voted() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        
        circuit_breaker.register_asset(token.contract_address, 7000, 1000000000000000000000);
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Trigger rate limit
        let amount: u256 = 10000000000000000000000;
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 6000000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        

        // Guardian 1 proposes
        let proposal_id: u256 = 1;
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.guardian_propose_rate_limit_override(proposal_id);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Check voting status
        assert_eq!(circuit_breaker.has_guardian_voted(proposal_id, guardian1), true); // Proposer auto-voted
        assert_eq!(circuit_breaker.has_guardian_voted(proposal_id, guardian2), false); // Hasn't voted yet

        // Guardian 2 votes
        start_cheat_caller_address(circuit_breaker.contract_address, guardian2);
        circuit_breaker.guardian_vote_rate_limit_override(proposal_id, true);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Check updated voting status
        assert_eq!(circuit_breaker.has_guardian_voted(proposal_id, guardian2), true); // Now has voted
    }

    #[test]
    #[should_panic(expected: ('Already voted',))]
    fn test_guardian_cannot_vote_twice() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian1);
        
        circuit_breaker.register_asset(token.contract_address, 7000, 1000000000000000000000);
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Trigger rate limit
        let amount: u256 = 10000000000000000000000;
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 6000000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
      

        // Guardian 1 proposes (auto-votes)
        let proposal_id: u256 = 1;
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.guardian_propose_rate_limit_override(proposal_id);
        
        // Try to vote again (should fail)
        circuit_breaker.guardian_vote_rate_limit_override(proposal_id, false);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }
}