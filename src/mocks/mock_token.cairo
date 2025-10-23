#[starknet::interface]
pub trait IMockToken<TContractState> {
    // Custom functions only - ERC20 functions are handled by ERC20MixinImpl
    fn mint(ref self: TContractState, to: starknet::ContractAddress, amount: u256);
    fn burn(ref self: TContractState, from: starknet::ContractAddress, amount: u256);
}

#[starknet::contract]
pub mod MockToken {
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl, DefaultConfig};
    use starknet::ContractAddress;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    // ERC20 Mixin impl - provides all standard ERC20 functions
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
    ) {
        self.erc20.initializer(name, symbol);
    }

    #[abi(embed_v0)]
    impl MockTokenImpl of super::IMockToken<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            self.erc20.mint(to, amount);
        }

        fn burn(ref self: ContractState, from: ContractAddress, amount: u256) {
            self.erc20.burn(from, amount);
        }
    }
}