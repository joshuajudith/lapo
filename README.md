# Lapo — NFT Rental Contract (Clarity)

This repository contains a simple Clarity smart contract that implements a minimal NFT rental listing and renting workflow compatible with the SIP-009 NFT trait.

The contract source is in `contracts/lapo.clar`.

## Overview

`lapo.clar` lets an NFT owner escrow their SIP-009 NFT into this contract and list it for rent at a specified STX price and duration (in blocks). A renter can then call `rent` to pay the owner and become the active renter for the configured duration (expiry = current block height + duration).

This implementation intentionally focuses on core listing and renting logic; it does not include features like canceling a listing, returning the NFT, or secondary flows (these are recommended enhancements).

## Key components

- Trait: `sip009-nft-trait`
  - Expected external NFT interface that `lapo` uses to interact with NFTs.
  - Methods used:
    - `transfer? (uint principal principal) (response bool uint)` — escrow the NFT into the contract.
    - `get-owner? (uint) (response (optional principal) uint)` — check the current owner of a token.

- Errors (constants):
  - `ERR-NOT-FOUND (u100)` — listing does not exist.
  - `ERR-ALREADY-LISTED (u101)` — token already listed and available.
  - `ERR-INVALID-PRICE (u102)` — price must be > 0.
  - `ERR-INVALID-DURATION (u103)` — duration must be > 0.
  - `ERR-ALREADY-RENTED (u104)` — listing already rented.
  - `ERR-NOT-OWNER (u105)` — caller is not the token owner (or owner unknown).
  - `ERR-ESCROW-FAILED (u106)` — transfer? (escrow) call failed.
  - `ERR-NOT-ESCROWED (u107)` — token is not currently escrowed by this contract.
  - `ERR-STX-TRANSFER-FAILED (u108)` — STX payment failed.

- Storage: `rentals` map
  - Key: `token-id (uint)`
  - Value object fields:
    - `nft-owner: principal` — owner who listed the token.
    - `renter: (optional principal)` — current renter or `none` if available.
    - `expiry: uint` — block height when rental expires (set when rented).
    - `price: uint` — STX price required to rent.
    - `duration: uint` — duration (in blocks) for the rental.

## Public functions

- `offer-for-rent (nft <sip009-nft-trait>) (token-id uint) (price uint) (duration uint)`
  - Called by the NFT owner to create a listing and escrow the NFT into this contract.
  - Validation: `price > 0`, `duration > 0`.
  - Ensures caller is owner via `get-owner?` and then calls `transfer?` to escrow the token to `.lapo`.
  - On success writes a `rentals` entry with `renter: none` and `expiry: u0`.
  - Returns `(ok true)` on success or an appropriate `(err ERR-*)` code.

- `rent (nft <sip009-nft-trait>) (token-id uint)`
  - Called by a renter to rent a listed token.
  - Validates listing exists and `renter` is `none` (available).
  - Verifies the token is still escrowed (owner is `.lapo`) via `get-owner?`.
  - Performs an `stx-transfer? price tx-sender owner` to transfer STX to the listing owner.
  - On success writes update to `rentals` with `renter: (some tx-sender)` and `expiry = stacks-block-height + duration`.
  - Returns `(ok true)` on success or an `(err ERR-*)` on error.

## Important notes & limitations

- There is no `cancel-offer` or `return` function in this contract. Once the owner calls `offer-for-rent` and the NFT is escrowed, there is no provided method to return the NFT to the owner or to automatically release it after expiry. Implementing those flows is necessary for a production-ready rental contract.

- The contract masks external NFT errors by using `unwrap!` with its own error codes (e.g., `ERR-NOT-OWNER`, `ERR-NOT-ESCROWED`). If you prefer to surface NFT contract error codes, change the pattern to match the response instead of `unwrap!`.

- There is no platform fee, no rental extension mechanism, and no explicit tenant access control other than recording the `renter` in the `rentals` map.

## Suggested next steps / improvements

- Add the following public functions:
  - `cancel-offer` — allow owner to cancel a listing and transfer the NFT back if `renter` is `none`.
  - `end-rental` or `release-nft` — called after `expiry` to clear `renter` and optionally transfer or return the NFT.
  - `modify-listing` — allow owner to change price/duration while not rented.
  - `get-listing` — a read-only function returning listing details for a token-id.

- Testing:
  - Add unit tests (Clarinet / Mocha + Typescript tests already present in `tests/lapo.test.ts`) covering happy paths and error paths:
    - Offer by non-owner, offer with invalid price/duration.
    - Offer success and escrow verification.
    - Rent success and STX transfer failures (renter insufficient balance).
    - Attempt to rent non-listed token.
    - Confirm expiry calculation.

- UX/fees:
  - Add a platform fee mechanism (split STX transfer between owner and platform).
  - Consider holding STX in contract until rental completion if refunds are needed on failure.

## Example usage (Clarinet / contract-call?)

The following are conceptual examples; adjust for your environment and Clarinet test fixtures:

- Owner lists token 42 with price 10 STX and duration 1000 blocks:

    (contract-call? .lapo offer-for-rent <nft-contract> u42 u10 u1000)

- Renter rents token 42:

    (contract-call? .lapo rent <nft-contract> u42)

Replace `<nft-contract>` with your SIP-009 contract principal (e.g. `SP2... .my-nft`).

## Files of interest

- `contracts/lapo.clar` — main contract implementation.
- `tests/lapo.test.ts` — project test file to extend or run.
- `Clarinet.toml` and `settings/` — Clarinet configuration for testnets/devnet.

## Running tests

This repository includes a `package.json` and a `tests/` folder. You can run the project's tests using the npm script:

Or run Clarinet checks directly if you have Clarinet installed:

```powershell
clarinet check
```

## License & attribution

This repository is provided as-is for educational and prototyping purposes. Review and harden the contract before deploying to mainnet
