
import { beforeEach, describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";
import type { ClarityValue } from "@stacks/transactions";

const CONTRACT_NAME = "lapo";
const NFT_CONTRACT_NAME = "mock-nft";

const mockNftContract = `
(impl-trait .lapo.sip009-nft-trait)

(define-map owner-of uint principal)
(define-data-var next-id uint u1)

(define-public (mint (recipient principal))
  (let ((id (var-get next-id)))
    (begin
      (map-set owner-of id recipient)
      (var-set next-id (+ id u1))
      (ok id))))

(define-read-only (get-owner? (token-id uint))
  (ok (map-get? owner-of token-id)))

(define-public (transfer? (token-id uint) (sender principal) (recipient principal))
  (match (map-get? owner-of token-id)
    owner
      (if (is-eq owner sender)
          (begin (map-set owner-of token-id recipient) (ok true))
          (err u401))
    (err u404)))
`;

let deployer: string;
let owner: string;
let renter: string;
let other: string;

beforeEach(async () => {
  await simnet.initSession(process.cwd(), "./Clarinet.toml");
  const accounts = simnet.getAccounts();
  deployer = accounts.get("deployer")!;
  owner = accounts.get("wallet_1")!;
  renter = accounts.get("wallet_2")!;
  other = accounts.get("wallet_3")!;
});

function deployMockNft() {
  const deploy = simnet.deployContract(
    NFT_CONTRACT_NAME,
    mockNftContract,
    { clarityVersion: 3 },
    deployer,
  );
  expect(deploy.result).toBeBool(true);
}

function mintTo(recipient: string, expectedId: bigint = 1n) {
  const mint = simnet.callPublicFn(
    NFT_CONTRACT_NAME,
    "mint",
    [Cl.principal(recipient)],
    deployer,
  );
  expect(mint.result).toBeOk(Cl.uint(expectedId));
}

function listForRent(tokenId: bigint, price: bigint, duration: bigint, lister: string = owner) {
  const res = simnet.callPublicFn(
    CONTRACT_NAME,
    "offer-for-rent-secure",
    [
      Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME),
      Cl.uint(tokenId),
      Cl.uint(price),
      Cl.uint(duration),
    ],
    lister,
  );
  expect(res.result).toBeOk(Cl.bool(true));
}

function callGetRental(tokenId: bigint) {
  return simnet.callReadOnlyFn(
    CONTRACT_NAME,
    "get-rental-info",
    [Cl.uint(tokenId)],
    owner,
  ).result as ClarityValue;
}

describe("lapo rental flows", () => {
  it("escrows an NFT and stores listing metadata", () => {
    deployMockNft();
    mintTo(owner);

    const tokenId = 1n;
    const price = 100n;
    const duration = 5n;

    const lapoPrincipal = Cl.contractPrincipal(deployer, CONTRACT_NAME);

    listForRent(tokenId, price, duration);

    const listing = callGetRental(tokenId);
    expect(listing).toBeSome(
      Cl.tuple({
        "nft-owner": Cl.principal(owner),
        renter: Cl.none(),
        expiry: Cl.uint(0),
        price: Cl.uint(price),
        duration: Cl.uint(duration),
      }),
    );

    const { result: ownerAfterEscrow } = simnet.callReadOnlyFn(
      NFT_CONTRACT_NAME,
      "get-owner?",
      [Cl.uint(tokenId)],
      owner,
    );
    expect(ownerAfterEscrow).toBeOk(Cl.some(lapoPrincipal));
  });

  it("rents a listed NFT and marks it active", () => {
    deployMockNft();
    mintTo(owner);

    const tokenId = 1n;
    const price = 42n;
    const duration = 3n;

    listForRent(tokenId, price, duration);

    const rent = simnet.callPublicFn(
      CONTRACT_NAME,
      "rent-secure",
      [Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME), Cl.uint(tokenId)],
      renter,
    );
  expect(rent.result).toBeOk(Cl.bool(true));

    const expectedExpiry = Cl.uint(BigInt(simnet.stacksBlockHeight) + duration);

    const rentalInfo = callGetRental(tokenId);
    expect(rentalInfo).toBeSome(
      Cl.tuple({
        "nft-owner": Cl.principal(owner),
        renter: Cl.some(Cl.principal(renter)),
        expiry: expectedExpiry,
        price: Cl.uint(price),
        duration: Cl.uint(duration),
      }),
    );

    const active = simnet.callReadOnlyFn(
      CONTRACT_NAME,
      "is-rental-active",
      [Cl.uint(tokenId)],
      renter,
    );
    expect(active.result).toBeBool(true);
  });

  it("returns an expired rental and clears state", () => {
    deployMockNft();
    mintTo(owner);

    const tokenId = 1n;
    const price = 50n;
    const duration = 2n;

    listForRent(tokenId, price, duration);
    simnet.callPublicFn(
      CONTRACT_NAME,
      "rent-secure",
      [Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME), Cl.uint(tokenId)],
      renter,
    );

    simnet.mineEmptyBlocks(Number(duration) + 1);

    const returned = simnet.callPublicFn(
      CONTRACT_NAME,
      "return-expired-nft",
      [Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME), Cl.uint(tokenId)],
      other,
    );
    expect(returned.result).toBeOk(Cl.bool(true));

    const listing = callGetRental(tokenId);
    expect(listing).toBeNone();

    const { result: ownerAfterReturn } = simnet.callReadOnlyFn(
      NFT_CONTRACT_NAME,
      "get-owner?",
      [Cl.uint(tokenId)],
      owner,
    );
    expect(ownerAfterReturn).toBeOk(Cl.some(Cl.principal(owner)));
  });

  it("allows the renter to early-return before expiry", () => {
    deployMockNft();
    mintTo(owner);

    const tokenId = 1n;
    const price = 25n;
    const duration = 10n;

    listForRent(tokenId, price, duration);
    simnet.callPublicFn(
      CONTRACT_NAME,
      "rent-secure",
      [Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME), Cl.uint(tokenId)],
      renter,
    );

    const early = simnet.callPublicFn(
      CONTRACT_NAME,
      "early-return",
      [Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME), Cl.uint(tokenId)],
      renter,
    );
    expect(early.result).toBeOk(Cl.bool(true));

    const listing = callGetRental(tokenId);
    expect(listing).toBeNone();

    const { result: ownerAfterReturn } = simnet.callReadOnlyFn(
      NFT_CONTRACT_NAME,
      "get-owner?",
      [Cl.uint(tokenId)],
      owner,
    );
    expect(ownerAfterReturn).toBeOk(Cl.some(Cl.principal(owner)));
  });

  it("rejects invalid price or duration on listing", async () => {
    deployMockNft();
    mintTo(owner);
    const tokenId = 1n;

    const invalidPrice = simnet.callPublicFn(
      CONTRACT_NAME,
      "offer-for-rent-secure",
      [
        Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME),
        Cl.uint(tokenId),
        Cl.uint(0),
        Cl.uint(5),
      ],
      owner,
    );
    expect(invalidPrice.result).toBeErr(Cl.uint(102));

    // re-init to reset the reentrancy guard after the failed call
    await simnet.initSession(process.cwd(), "./Clarinet.toml");
    deployMockNft();
    mintTo(owner);

    const invalidDuration = simnet.callPublicFn(
      CONTRACT_NAME,
      "offer-for-rent-secure",
      [
        Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME),
        Cl.uint(tokenId),
        Cl.uint(10),
        Cl.uint(0),
      ],
      owner,
    );
    expect(invalidDuration.result).toBeErr(Cl.uint(103));
  });

  it("prevents non-owners from listing", () => {
    deployMockNft();
    mintTo(owner);
    const tokenId = 1n;

    const notOwner = simnet.callPublicFn(
      CONTRACT_NAME,
      "offer-for-rent-secure",
      [
        Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME),
        Cl.uint(tokenId),
        Cl.uint(10),
        Cl.uint(5),
      ],
      renter,
    );
    expect(notOwner.result).toBeErr(Cl.uint(105));
  });

  it("blocks state changes when paused", () => {
    deployMockNft();
    mintTo(owner);
    const tokenId = 1n;

    const paused = simnet.callPublicFn(CONTRACT_NAME, "pause-contract", [], deployer);
    expect(paused.result).toBeOk(Cl.bool(true));

    const afterPause = simnet.callPublicFn(
      CONTRACT_NAME,
      "offer-for-rent-secure",
      [
        Cl.contractPrincipal(deployer, NFT_CONTRACT_NAME),
        Cl.uint(tokenId),
        Cl.uint(10),
        Cl.uint(5),
      ],
      owner,
    );
    expect(afterPause.result).toBeErr(Cl.uint(113));
  });
});
