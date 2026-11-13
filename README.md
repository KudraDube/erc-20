# MyToken (ERC-20 from scratch)

A fungible token written without any library, to understand exactly what an ERC-20 does line by line.

Think of a bank where the contract is the ledger. `transfer` moves your own money. `approve` signs a slip saying "Bob may take up to 50 from my account". `transferFrom` is Bob handing in that slip to take money from someone else's account.

## Why I built it

ERC-20 is the simplest contract that shows I understand balances, allowances and events, and it is the one most often asked for in a live interview. The hardest part is not the code. It is keeping straight who is `from`, who is `msg.sender` and whose allowance slot is read. In `transferFrom` the caller is the spender, so the slot is `allowance[from][msg.sender]`.

## Status

| Item | State |
|---|---|
| Contract | Complete, matches the Contracts Pack version |
| Tests | 43 passing (unit, allowance edge cases, fuzz, invariant) |
| Audit | None. This is a learning project, **do not deploy with real funds** |

## How it works

| Piece | Job |
|---|---|
| `balanceOf` | Each address's balance |
| `allowance[owner][spender]` | How much the spender may still take from the owner |
| `transfer` | Moves the caller's own tokens |
| `approve` | SETS the spender's allowance. It does not add. |
| `transferFrom` | Spends the caller's allowance to move someone else's tokens |
| `_transfer` | The one internal function that checks the zero address and the balance and then moves tokens |
| Custom errors | `ZeroAddress`, `InsufficientBalance`, `InsufficientAllowance` |

## Design decisions

- **`approve` sets instead of adds.** Adding makes the numbers drift from what the owner intended and breaks the standard.
- **An explicit allowance check in `transferFrom`.** Without it the call would only fail through a raw arithmetic underflow panic. Now it reverts with a clear error.
- **Allowance is read, checked, reduced and only then are tokens moved.**
- **A max allowance (`type(uint256).max`) is never reduced.** This is the common convention and saves a storage write on every spend. A test confirms the balance check still protects the owner.
- **One `_transfer` function** so every movement of tokens goes through the same checks.

## Known limitations

- **The approve race condition.** If the owner changes an allowance from 50 to 30 then the spender can spend 50 first and 30 after the change lands. The test `test_approveRace_documentedWeakness` shows it. Mitigations are to set to 0 first, to add increase and decrease functions or to use `permit`.
- **Supply is fixed.** `_mint` runs once in the constructor and `_burn` is internal and never called, so nobody can mint or burn after deployment.
- **Tokens sent to the contract's own address are stuck.** Only the zero address is blocked.
- **No `permit`, no `increaseAllowance` and no `decreaseAllowance`.**
- **`approve` does not reject a zero spender address**, which is harmless but not what OpenZeppelin does.
- **Not audited.**

## Tests

`test/MyToken.t.sol`, 43 tests:

- metadata and the constructor mint with its event
- `transfer`: balances, event, exact balance, zero amount, to self, over balance and to zero
- `approve`: set not add, event, reset to zero and per-spender separation
- `transferFrom`: who spends, event, the whole allowance, used-up allowance, an unapproved caller, the owner needing allowance too, a failed call leaving the allowance unchanged and max allowance
- `_mint` and `_burn` through a harness contract
- fuzz tests for conservation, over-balance reverts and exact allowance reduction
- 2 invariants after random transfers, approvals, spends, mints and burns

## Run it

```bash
forge install foundry-rs/forge-std
forge test
```

## What I practised

- writing a whole ERC-20 from blank paper and explaining who `from` and `msg.sender` are
- the allowance slot `allowance[owner][spender]` and why max allowance is not reduced
- custom errors instead of revert strings
- testing internal functions through a harness
- writing a test that proves a known weakness (the approve race) instead of hiding it
- invariant testing with a handler

## Where this is going

I am a WeThinkCode blockchain graduate building towards a junior Solidity or Web3 role. This repository is one of a set (ERC-20, SimpleDEX, EthVault, MultiSigWallet, P2PEscrow, StakingRewards, TieredPass1155) where each contract comes with tests I can explain line by line.
