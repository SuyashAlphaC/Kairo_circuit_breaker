use core::panic_with_felt252;
use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store)]
pub struct LiqChangeNode {
    pub next_timestamp: u64,
    pub amount: SignedU256,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Limiter {
    pub min_liq_retained_bps: u256,
    pub limit_begin_threshold: u256,
    pub liq_total: SignedU256,
    pub liq_in_period: SignedU256,
    pub list_head: u64,
    pub list_tail: u64,
    pub initialized: bool,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct SignedU256 {
    pub value: u256,
    pub is_negative: bool,
}

#[derive(Drop, Copy, PartialEq)]
pub enum LimitStatus {
    Uninitialized,
    Inactive,
    Ok,
    Triggered,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct GuardianOverrideProposal {
    pub proposer: ContractAddress,
    pub votes_for: u32,
    pub votes_against: u32,
    pub creation_timestamp: u64,
    pub executed: bool,
}

#[generate_trait]
pub impl SignedU256Impl of SignedU256Trait {
    fn new(value: u256, is_negative: bool) -> SignedU256 {
        SignedU256 { value, is_negative }
    }

    fn from_u256(value: u256) -> SignedU256 {
        SignedU256 { value, is_negative: false }
    }

    fn add(self: SignedU256, other: SignedU256) -> SignedU256 {
        if self.is_negative == other.is_negative {
            // Same sign, add values
            SignedU256 { value: self.value + other.value, is_negative: self.is_negative }
        } else {
            // Different signs, subtract
            if self.value >= other.value {
                SignedU256 { value: self.value - other.value, is_negative: self.is_negative }
            } else {
                SignedU256 { value: other.value - self.value, is_negative: other.is_negative }
            }
        }
    }

    fn sub(self: SignedU256, other: SignedU256) -> SignedU256 {
        let negated_other = SignedU256 { value: other.value, is_negative: !other.is_negative };
        self.add(negated_other)
    }

    fn mul_bps(self: SignedU256, bps: u256) -> SignedU256 {
        let result_value = (self.value * bps) / 10000_u256;
        SignedU256 { value: result_value, is_negative: self.is_negative }
    }

    fn is_less_than(self: SignedU256, other: SignedU256) -> bool {
        if self.is_negative && !other.is_negative {
            true
        } else if !self.is_negative && other.is_negative {
            false
        } else if self.is_negative && other.is_negative {
            self.value > other.value // For negative numbers, larger absolute value means smaller
        } else {
            self.value < other.value
        }
    }

    fn to_u256(self: SignedU256) -> u256 {
        if self.is_negative {
            panic_with_felt252('Cannot convert negative to u256')
        } else {
            self.value
        }
    }

    fn zero() -> SignedU256 {
        SignedU256 { value: 0, is_negative: false }
    }
}