# RegulatedToken

A compliance-style ERC-20 for a regulated asset (here a rand stablecoin, rZAR). It has a supply cap and separate roles for minting and pausing. A compliance officer can freeze accounts, and holders can approve spenders with a signature (permit).

Think of a bank vault with three different key holders. One can add money (up to the legal limit). One can lock the whole building in an emergency. One can freeze a single customer's account. None of them can do the others' jobs.

## Why I built it

Regulated tokens such as stablecoins and tokenised securities have to be controllable in ways a plain ERC-20 is not. I wanted to learn how real ones are built from OpenZeppelin parts and how to put every rule in one place so no code path can bypass it. The central idea is the `_update` hook in OpenZeppelin v5: every mint, burn and transfer goes through it.

## Status

| Item | State |
|---|---|
| Contract | Complete, patched with the Contracts Pack fix |
| Tests | Over 50 passing (unit, roles, permit, fuzz, invariant) |
| Audit | None. This is a learning project, **do not deploy with real funds** |

## How it works

| Piece | Job |
|---|---|
| `MINTER_ROLE` | Can mint, up to the cap |
| `PAUSER_ROLE` | Can pause and unpause all balance movements |
| `COMPLIANCE_ROLE` | Can blacklist and unblacklist accounts |
| `cap` (immutable) | The most that can exist at once. It lives in bytecode so there is no storage read. |
| `_update` override | The single door. Checks the blacklist, runs the pause check and the balance update, then enforces the cap on mints |
| `ERC20Permit` | Lets a holder approve a spender with a signature instead of a transaction |

In OpenZeppelin v5, `from == address(0)` means a mint and `to == address(0)` means a burn.

## What I patched and why

The original checked the cap inside `mint()`. Any future function that calls `_mint` directly would skip that check. I moved the cap check into `_update`, after `super._update`, so the supply has already grown when it is compared to the cap. Now the rule holds on every mint path.

I also replaced my old cap test. It minted about 1000 times the whole cap, so it would pass even with a badly wrong check. The new tests mint exactly one wei over the cap and check the exact error. A harness contract with an unchecked mint function proves the patch. These tests fail against the original and pass against the patched version.

## Design decisions

- **One choke point.** The blacklist, pause and cap rules all live in `_update`.
- **`super._update` is called before the cap check** so the pause check and the accounting run first.
- **Separate roles** so a leaked pauser key cannot mint and a minter cannot freeze accounts.
- **A frozen account keeps its balance.** Blacklisting blocks movement but does not confiscate anything.
- **Permit** removes the extra approval transaction, which saves a user gas and a step.

## Known limitations

- **The admin holds every role at deploy.** That is a centralisation risk. A real deployment would split the roles across addresses and put the admin behind a multisig.
- **Only `from` and `to` are checked for the blacklist.** A blacklisted spender can still move an owner's tokens through `transferFrom`. A test documents this.
- **Blacklisting the zero address freezes every mint and burn**, because mints have `from == 0` and burns have `to == 0`.
- **Pause stops balance movements only.** Approvals and permits still work while paused.
- **The cap applies to current supply.** Burning frees room to mint again.
- **No public burn function** and no way to confiscate frozen funds.
- **No check that the admin address is valid.** A zero admin would leave nobody with any role.
- **Not audited.**

## Tests

`test/RegulatedToken.t.sol`:

- metadata, the cap and the roles set by the constructor
- mint access control and the cap, including exactly one wei over
- the patch, using a harness that mints without any checks
- pause: transfers, `transferFrom`, mints and burns blocked, and approvals still allowed
- blacklist: sender, receiver, mint target and burn source, unblacklisting, and the documented gaps
- roles: each role only does its own job
- permit: signature, replay, expiry, wrong signer and changed value
- fuzz tests for the cap, the blacklist and pause
- 2 invariants after random mints, burns, transfers, pauses and blacklisting: supply never exceeds the cap and balances add up to the supply

## Run it

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
```

A simpler from-scratch ERC-20 (`MyToken`) is in `src/` for comparison.

## What I practised

- the OpenZeppelin v5 `_update` hook and why one choke point is safer than checks scattered across functions
- role-based access control with several roles
- EIP-2612 permit and signing in tests with `vm.sign`
- testing a guard against a future mistake with a harness contract
- writing tests that document known gaps instead of hiding them
- invariant testing with a handler

## Where this is going

I am a WeThinkCode blockchain graduate building towards a junior Solidity or Web3 role. This repository is one of a set (SimpleDEX, EthVault, MultiSigWallet, P2PEscrow, StakingRewards, TieredPass1155, RegulatedToken) where each contract comes with tests I can explain line by line.
