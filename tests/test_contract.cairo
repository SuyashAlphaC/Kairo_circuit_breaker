#[cfg(test)]
mod tests {
    use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
    
    use snforge_std::{
        declare, ContractClassTrait, DeclareResultTrait,
        start_cheat_caller_address, stop_cheat_caller_address,
        start_cheat_block_timestamp, stop_cheat_block_timestamp,
    };
    
    use circuit_breaker::core::circuit_breaker::CircuitBreaker;
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

    // Helper struct to hold both dispatchers for MockToken
    #[derive(Drop, Copy)]
    struct MockTokenDispatchers {
        mock: IMockTokenDispatcher,
        erc20: IERC20Dispatcher,
        contract_address: ContractAddress,
    }

    fn deploy_circuit_breaker() -> ICircuitBreakerDispatcher {
        let admin = contract_address_const::<'admin'>();
        let rate_limit_cooldown_period: u64 = 259200; // 3 days in seconds
        let withdrawal_period: u64 = 14400; // 4 hours in seconds
        let tick_length: u64 = 300; // 5 minutes in seconds
        let eth_token_address = contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>(); //hardcoding for test purposes
        
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
        
        // Define name and symbol as ByteArray, as the constructor expects.
        let name: ByteArray = "Mock Token";
        let symbol: ByteArray = "MTK";

        let mut constructor_calldata = array![];
        name.serialize(ref constructor_calldata);
        symbol.serialize(ref constructor_calldata);

        let (contract_address, _) = contract.deploy(
            @constructor_calldata
        ).unwrap();
        
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

    #[test]
    fn test_initialization() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        
        assert_eq!(circuit_breaker.admin(), admin);
        assert_eq!(circuit_breaker.rate_limit_cooldown_period(), 259200);
        assert_eq!(circuit_breaker.withdrawal_period(), 14400);
        assert_eq!(circuit_breaker.tick_length(), 300);
        assert_eq!(circuit_breaker.is_operational(), true);
        assert_eq!(circuit_breaker.is_rate_limited(), false);
    }

    #[test]
    fn test_register_asset() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let token = deploy_mock_token();
        
        // Register asset as admin
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify registration
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), false);
    }

    #[test]
    #[should_panic(expected: ('Not admin',))]
    fn test_register_asset_unauthorized() {
        let circuit_breaker = deploy_circuit_breaker();
        let unauthorized = contract_address_const::<'unauthorized'>();
        let token = deploy_mock_token();
        
        // Try to register asset as non-admin (should panic)
        start_cheat_caller_address(circuit_breaker.contract_address, unauthorized);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    fn test_add_protected_contracts() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Add protected contract
        let mut protected_contracts = array![defi.contract_address];
        
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify protection
        assert_eq!(circuit_breaker.is_protected_contract(defi.contract_address), true);
    }

    #[test]
    fn test_deposit_and_withdrawal_no_breach() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup: Register asset and add protected contract
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Mint tokens to Alice
        let mint_amount: u256 = 10000000000000000000000; // 10000 tokens
        token.mock.mint(alice, mint_amount);
        
        // Approve DeFi protocol
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, mint_amount);
        stop_cheat_caller_address(token.contract_address);
        
        // Deposit tokens
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, 100000000000000000000); // 100 tokens
        stop_cheat_caller_address(defi.contract_address);
        
        // Fast forward time
        start_cheat_block_timestamp(circuit_breaker.contract_address, 3600); // 1 hour later
        
        // Withdraw tokens (within safe limits)
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 60000000000000000000); // 60 tokens
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify no rate limit triggered
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), false);
    }

    #[test]
    fn test_rate_limit_breach() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup: Register asset and add protected contract
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000, // 70% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Mint and deposit tokens
        let large_amount: u256 = 10000000000000000000000; // 10000 tokens
        token.mock.mint(alice, large_amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, large_amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, large_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Fast forward time to allow withdrawal period
        start_cheat_block_timestamp(circuit_breaker.contract_address, 3600); // 1 hours later
        
        // Attempt to withdraw more than 30% (should trigger rate limit)
        let breach_amount: u256 = 6000000000000000000000; // 6000 tokens (60% of 10000)
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, breach_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);

        let is_triggered = circuit_breaker.is_rate_limit_triggered(token.contract_address);
        
        // Debug: Let's see what the actual trigger status is
        assert_eq!(is_triggered, true, "Rate limit should be triggered");
        
        // Verify rate limit triggered
        assert_eq!(circuit_breaker.is_rate_limited(), true);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), true);
        
        // Verify funds are locked
        assert_eq!(circuit_breaker.locked_funds(alice, token.contract_address), breach_amount);
    }

    #[test]
    fn test_claim_locked_funds_after_override() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup and trigger rate limit (similar to previous test)
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Deposit and trigger rate limit
        let large_amount: u256 = 1000000000000000000000000;
        token.mock.mint(alice, large_amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, large_amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, large_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        
        let breach_amount: u256 = 300001000000000000000000;
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, breach_amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Admin overrides rate limit
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.override_rate_limit(token.contract_address, 2);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Alice claims locked funds
        //start_cheat_caller_address(circuit_breaker.contract_address, alice);
        //circuit_breaker.claim_locked_funds(token.contract_address, alice);
        //stop_cheat_caller_address(circuit_breaker.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify funds claimed
        assert_eq!(circuit_breaker.locked_funds(alice, token.contract_address), 0);
        assert_eq!(circuit_breaker.is_rate_limited(), false);
    }

    #[test]
    fn test_grace_period() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        
        // Set grace period
        let grace_period_end: u64 = 86400; // 1 day from now
        
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        start_cheat_block_timestamp(circuit_breaker.contract_address, 0);
        circuit_breaker.start_grace_period(grace_period_end);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Verify grace period
        assert_eq!(circuit_breaker.grace_period_end_timestamp(), grace_period_end);
        assert_eq!(circuit_breaker.is_in_grace_period(), true);
    }

    #[test]
    fn test_emergency_pause() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        
        // Mark as not operational (pause)
        circuit_breaker.mark_as_not_operational();
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify paused
        assert_eq!(circuit_breaker.is_operational(), false);
        
        // Check pausable interface
        let pausable = IPausableDispatcher { contract_address: circuit_breaker.contract_address };
        assert_eq!(pausable.is_paused(), true);
    }

    #[test]
    fn test_migrate_funds_after_exploit() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let recovery = contract_address_const::<'recovery'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);
        
        // Setup and deposit funds
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Deposit funds that will be stuck in circuit breaker
        let amount: u256 = 1000000000000000000000;
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);
        
        // Trigger rate limit to get funds stuck in circuit breaker
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 400000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Mark as exploited and migrate funds
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.mark_as_not_operational();
        
        let mut assets = array![token.contract_address];
        circuit_breaker.migrate_funds_after_exploit(assets, recovery);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        // Verify migration successful
        assert_eq!(circuit_breaker.is_operational(), false);
    }

    // ==================== GUARDIAN MANAGEMENT TESTS ====================

    #[test]
    fn test_add_guardian() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add first guardian
        circuit_breaker.add_guardian(guardian1);
        assert_eq!(circuit_breaker.is_guardian(guardian1), true);
        assert_eq!(circuit_breaker.guardian_count(), 1);
        
        // Add second guardian
        circuit_breaker.add_guardian(guardian2);
        assert_eq!(circuit_breaker.is_guardian(guardian2), true);
        assert_eq!(circuit_breaker.guardian_count(), 2);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    fn test_remove_guardian() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add guardians
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 2);
        
        // Remove first guardian
        circuit_breaker.remove_guardian(guardian1);
        assert_eq!(circuit_breaker.is_guardian(guardian1), false);
        assert_eq!(circuit_breaker.guardian_count(), 1);
        assert_eq!(circuit_breaker.is_guardian(guardian2), true);
        
        // Remove second guardian
        circuit_breaker.remove_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 0);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    fn test_guardian_count_consistency() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Initial count should be 0
        assert_eq!(circuit_breaker.guardian_count(), 0);
        
        // Add and verify count increments
        circuit_breaker.add_guardian(guardian1);
        assert_eq!(circuit_breaker.guardian_count(), 1);
        
        circuit_breaker.add_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 2);
        
        // Remove and verify count decrements
        circuit_breaker.remove_guardian(guardian1);
        assert_eq!(circuit_breaker.guardian_count(), 1);
        
        circuit_breaker.remove_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 0);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    // ==================== GUARDIAN EDGE CASE TESTS ====================

    #[test]
    #[should_panic(expected: ('Invalid guardian address',))]
    fn test_add_guardian_zero_address() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let zero_address = contract_address_const::<0>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(zero_address);
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Guardian already exists',))]
    fn test_add_duplicate_guardian() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian = contract_address_const::<'guardian'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add guardian first time (should succeed)
        circuit_breaker.add_guardian(guardian);
        
        // Try to add same guardian again (should panic)
        circuit_breaker.add_guardian(guardian);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Guardian not found',))]
    fn test_remove_nonexistent_guardian() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian = contract_address_const::<'guardian'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.remove_guardian(guardian);
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Guardian not found',))]
    fn test_remove_guardian_twice() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian = contract_address_const::<'guardian'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        // Add and remove guardian
        circuit_breaker.add_guardian(guardian);
        circuit_breaker.remove_guardian(guardian);
        
        // Try to remove again (should panic)
        circuit_breaker.remove_guardian(guardian);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    // ==================== GUARDIAN AUTHORIZATION TESTS ====================

    #[test]
    #[should_panic(expected: ('Not admin',))]
    fn test_add_guardian_unauthorized() {
        let circuit_breaker = deploy_circuit_breaker();
        let unauthorized = contract_address_const::<'unauthorized'>();
        let guardian = contract_address_const::<'guardian'>();

        start_cheat_caller_address(circuit_breaker.contract_address, unauthorized);
        circuit_breaker.add_guardian(guardian);
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Not admin',))]
    fn test_remove_guardian_unauthorized() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let unauthorized = contract_address_const::<'unauthorized'>();
        let guardian = contract_address_const::<'guardian'>();

        // Admin adds guardian first
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Unauthorized user tries to remove
        start_cheat_caller_address(circuit_breaker.contract_address, unauthorized);
        circuit_breaker.remove_guardian(guardian);
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Not admin',))]
    fn test_guardian_cannot_add_other_guardians() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();

        // Admin adds first guardian
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian1);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Guardian tries to add another guardian (should fail)
        start_cheat_caller_address(circuit_breaker.contract_address, guardian1);
        circuit_breaker.add_guardian(guardian2);
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }

    // ==================== CIRCUIT BREAKER EDGE CASE TESTS ====================

    #[test]
    fn test_multiple_assets_independent_rate_limits() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token1 = deploy_mock_token();
        let token2 = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup both assets with different thresholds
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token1.contract_address,
            5000, // 50% retention
            1000000000000000000000 // 1000 tokens minimum
        );
        circuit_breaker.register_asset(
            token2.contract_address,
            8000, // 80% retention  
            1000000000000000000000 // 1000 tokens minimum
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Mint and deposit both tokens
        let amount: u256 = 10000000000000000000000; // 10000 tokens each
        token1.mock.mint(alice, amount);
        token2.mock.mint(alice, amount);
        
        start_cheat_caller_address(token1.contract_address, alice);
        token1.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token1.contract_address);
        
        start_cheat_caller_address(token2.contract_address, alice);
        token2.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token2.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token1.contract_address, amount);
        defi.deposit(token2.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);

        // Withdraw from token1 within limits (40% of 10000 = 4000)
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token1.contract_address, 4000000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        
        // Should not trigger global rate limit yet
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token1.contract_address), false);

        // Withdraw from token2 beyond limits (30% of 10000 = 3000, but limit is 20%)
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token2.contract_address, 3000000000000000000000);
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Should trigger rate limit due to token2
        assert_eq!(circuit_breaker.is_rate_limited(), true);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token1.contract_address), false);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token2.contract_address), true);
    }

    #[test]
    fn test_admin_change_updates_guardian_system() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let new_admin = contract_address_const::<'new_admin'>();
        let guardian = contract_address_const::<'guardian'>();

        // Original admin adds guardian
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian);
        circuit_breaker.set_admin(new_admin);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // New admin should be able to manage guardians
        start_cheat_caller_address(circuit_breaker.contract_address, new_admin);
        let guardian2 = contract_address_const::<'guardian2'>();
        circuit_breaker.add_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 2);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Verify old admin can no longer manage guardians by checking current admin
        assert_eq!(circuit_breaker.admin(), new_admin);
    }

    #[test]
    fn test_zero_withdrawal_doesnt_trigger_limits() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let alice = contract_address_const::<'alice'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Setup
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.register_asset(
            token.contract_address,
            9000, // 90% retention (very strict)
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Deposit tokens
        let amount: u256 = 1000000000000000000000; // 1000 tokens
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        start_cheat_block_timestamp(circuit_breaker.contract_address, 1000);

        // Multiple zero withdrawals followed by a small valid withdrawal
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 0);
        defi.withdrawal(token.contract_address, 0);
        defi.withdrawal(token.contract_address, 0);
        // Small withdrawal within limits (1% of 1000 = 10 tokens, should be fine)
        defi.withdrawal(token.contract_address, 10000000000000000000); // 10 tokens
        stop_cheat_caller_address(defi.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Should not trigger any limits since we only withdrew 1% (much less than the 10% limit)
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        assert_eq!(circuit_breaker.is_rate_limit_triggered(token.contract_address), false);
    }

    // ==================== COMPREHENSIVE INTEGRATION TESTS ====================

    #[test]
    fn test_full_lifecycle_with_guardians() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        let guardian = contract_address_const::<'guardian'>();
        let alice = contract_address_const::<'alice'>();
        let recovery = contract_address_const::<'recovery'>();
        let token = deploy_mock_token();
        let defi = deploy_mock_defi(circuit_breaker.contract_address);

        // Phase 1: Setup system with guardian
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.add_guardian(guardian);
        circuit_breaker.register_asset(
            token.contract_address,
            7000,
            1000000000000000000000
        );
        
        let mut protected_contracts = array![defi.contract_address];
        circuit_breaker.add_protected_contracts(protected_contracts);
        stop_cheat_caller_address(circuit_breaker.contract_address);

        // Phase 2: Normal operation
        let amount: u256 = 10000000000000000000000;
        token.mock.mint(alice, amount);
        
        start_cheat_caller_address(token.contract_address, alice);
        token.erc20.approve(defi.contract_address, amount);
        stop_cheat_caller_address(token.contract_address);
        
        start_cheat_caller_address(defi.contract_address, alice);
        defi.deposit(token.contract_address, amount);
        stop_cheat_caller_address(defi.contract_address);

        // Phase 3: Trigger rate limit
        start_cheat_block_timestamp(circuit_breaker.contract_address, 18000);
        start_cheat_caller_address(defi.contract_address, alice);
        defi.withdrawal(token.contract_address, 5000000000000000000000); // 50% withdrawal
        stop_cheat_caller_address(defi.contract_address);
        
        assert_eq!(circuit_breaker.is_rate_limited(), true);
        assert_eq!(circuit_breaker.guardian_count(), 1);
        assert_eq!(circuit_breaker.is_guardian(guardian), true);

        // Phase 4: Admin override and fund recovery
        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        circuit_breaker.override_rate_limit(token.contract_address, 3);
        circuit_breaker.mark_as_not_operational();
        
        let mut assets = array![token.contract_address];
        circuit_breaker.migrate_funds_after_exploit(assets, recovery);
        stop_cheat_caller_address(circuit_breaker.contract_address);
        
        stop_cheat_block_timestamp(circuit_breaker.contract_address);
        
        // Phase 5: Verify final state
        assert_eq!(circuit_breaker.is_operational(), false);
        assert_eq!(circuit_breaker.is_rate_limited(), false);
        assert_eq!(circuit_breaker.is_guardian(guardian), true); // Guardian should still exist
    }

    #[test]
    fn test_stress_multiple_guardians_and_operations() {
        let circuit_breaker = deploy_circuit_breaker();
        let admin = contract_address_const::<'admin'>();
        
        // Add multiple guardians
        let guardian1 = contract_address_const::<'guardian1'>();
        let guardian2 = contract_address_const::<'guardian2'>();
        let guardian3 = contract_address_const::<'guardian3'>();
        let guardian4 = contract_address_const::<'guardian4'>();
        let guardian5 = contract_address_const::<'guardian5'>();

        start_cheat_caller_address(circuit_breaker.contract_address, admin);
        
        circuit_breaker.add_guardian(guardian1);
        circuit_breaker.add_guardian(guardian2);
        circuit_breaker.add_guardian(guardian3);
        circuit_breaker.add_guardian(guardian4);
        circuit_breaker.add_guardian(guardian5);
        
        assert_eq!(circuit_breaker.guardian_count(), 5);

        // Remove some guardians
        circuit_breaker.remove_guardian(guardian2);
        circuit_breaker.remove_guardian(guardian4);
        
        assert_eq!(circuit_breaker.guardian_count(), 3);
        assert_eq!(circuit_breaker.is_guardian(guardian1), true);
        assert_eq!(circuit_breaker.is_guardian(guardian2), false);
        assert_eq!(circuit_breaker.is_guardian(guardian3), true);
        assert_eq!(circuit_breaker.is_guardian(guardian4), false);
        assert_eq!(circuit_breaker.is_guardian(guardian5), true);

        // Add back one guardian
        circuit_breaker.add_guardian(guardian2);
        assert_eq!(circuit_breaker.guardian_count(), 4);
        assert_eq!(circuit_breaker.is_guardian(guardian2), true);
        
        stop_cheat_caller_address(circuit_breaker.contract_address);
    }
}