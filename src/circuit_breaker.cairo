#[starknet::contract]
pub mod CircuitBreaker {
    use core::traits::Into;
    use core::traits::TryInto;
    use core::option::OptionTrait;
    use core::array::ArrayTrait;
    use core::byte_array::ByteArrayTrait;
   
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map
    };
    use core::pedersen::pedersen;
    use core::hash::HashStateTrait;
    use core::poseidon::PoseidonTrait;
    use crate::interfaces::circuit_breaker_interface::{ICircuitBreaker, ICircuitBreakerEvents};

    #[storage]
    struct Storage {
        paused_functions: Map<(ContractAddress, felt252), bool>,

        owner: ContractAddress,
   
        api_key_hash: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Paused: Paused,
        Resumed: Resumed,
        TripTriggered: TripTriggered,
        OwnershipTransferred: OwnershipTransferred,
    }

    #[derive(Drop, starknet::Event)]
    struct Paused {
        target_contract: ContractAddress,
        function_selector: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Resumed {
        target_contract: ContractAddress,
        function_selector: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct TripTriggered {
        target_contract: ContractAddress,
        function_selector: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_owner: ContractAddress, initial_api_key_hash: felt252) {
        self.owner.write(initial_owner);
        self.api_key_hash.write(initial_api_key_hash);
    }

    #[abi(embed_v0)]
    impl CircuitBreakerImpl of ICircuitBreaker<ContractState> {
        fn pause(ref self: ContractState, target_contract: ContractAddress, function_selector: felt252) {
            self._assert_only_owner();
            
            let key = (target_contract, function_selector);
            self.paused_functions.entry(key).write(true);
            
            let timestamp = get_block_timestamp();
            self.emit(Event::Paused(Paused {
                target_contract,
                function_selector,
                timestamp,
            }));
        }

        fn resume(ref self: ContractState, target_contract: ContractAddress, function_selector: felt252) {
            self._assert_only_owner();
            
            let key = (target_contract, function_selector);
            self.paused_functions.entry(key).write(false);
            
            let timestamp = get_block_timestamp();
            self.emit(Event::Resumed(Resumed {
                target_contract,
                function_selector,
                timestamp,
            }));
        }

        fn is_paused(self: @ContractState, target_contract: ContractAddress, function_selector: felt252) -> bool {
            let key = (target_contract, function_selector);
            self.paused_functions.entry(key).read()
        }

        fn check_and_trip(
            ref self: ContractState,
            target_contract: ContractAddress,
            function_selector: felt252,
            api_response: ByteArray,
            signature: Array<felt252>
        ) {
       
            self._verify_api_response(api_response.clone(), signature);
            
      
            if self._contains_trip_status(@api_response) {
               
                let key = (target_contract, function_selector);
                self.paused_functions.entry(key).write(true);
                
                let timestamp = get_block_timestamp();
                self.emit(Event::TripTriggered(TripTriggered {
                    target_contract,
                    function_selector,
                    timestamp,
                }));
                
                self.emit(Event::Paused(Paused {
                    target_contract,
                    function_selector,
                    timestamp,
                }));
            }
        }

        fn set_api_key_hash(ref self: ContractState, new_api_key_hash: felt252) {
            self._assert_only_owner();
            self.api_key_hash.write(new_api_key_hash);
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            self._assert_only_owner();
            let previous_owner = self.owner.read();
            self.owner.write(new_owner);
            
            self.emit(Event::OwnershipTransferred(OwnershipTransferred {
                previous_owner,
                new_owner,
            }));
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _assert_only_owner(self: @ContractState) {
            let caller = get_caller_address();
            let owner = self.owner.read();
            assert(caller == owner, 'Not owner');
        }

        fn _verify_api_response(self: @ContractState, api_response: ByteArray, signature: Array<felt252>) {

            let api_key_hash = self.api_key_hash.read();
            

            let response_hash = self._hash_byte_array(@api_response);
            
      
            let expected_signature = pedersen(api_key_hash, response_hash);
            assert(signature.len() > 0, 'Invalid signature');
            assert(*signature.at(0) == expected_signature, 'Invalid signature');
        }

        fn _hash_byte_array(self: @ContractState, data: @ByteArray) -> felt252 {

            let mut hasher = PoseidonTrait::new();
            

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


        fn _contains_trip_status(self: @ContractState, api_response: @ByteArray) -> bool {
            let trip_pattern: ByteArray = "TRIP";
            let pattern_len = trip_pattern.len();
            let response_len = api_response.len();
    
            let mut i = 0;
    

            while i + pattern_len <= response_len {
                let mut j = 0;
                let mut matches = true;
    
        
                while j < pattern_len {
                    let api_byte = api_response.at(i + j).unwrap_or(0);
                    let pattern_byte = trip_pattern.at(j).unwrap_or(0);
    
                    if api_byte != pattern_byte {
                        matches = false;
                        break;
                    }
                    j += 1;
                }
    
                if matches {
                    return true;
                }
    
                i += 1;
            }
    
            false
        }
    }
}
