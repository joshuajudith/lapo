(define-trait sip009-nft-trait
  (
    ;; SIP-009 core surface we rely on
    (transfer? (uint principal principal) (response bool uint))
    (get-owner? (uint) (response (optional principal) uint))
  )
)

(define-constant ERR-NOT-FOUND u100)
(define-constant ERR-ALREADY-LISTED u101)
(define-constant ERR-INVALID-PRICE u102)
(define-constant ERR-INVALID-DURATION u103)
(define-constant ERR-ALREADY-RENTED u104)
(define-constant ERR-NOT-OWNER u105)
(define-constant ERR-ESCROW-FAILED u106)
(define-constant ERR-NOT-ESCROWED u107)
(define-constant ERR-STX-TRANSFER-FAILED u108)

;; Rentals registry:
;; - renter is optional to represent 'not rented yet'
;; - duration stored to compute expiry when renting
(define-map rentals
  uint
  {
    nft-owner: principal,
    renter: (optional principal),
    expiry: uint,
    price: uint,
    duration: uint
  }
)

;; Offer an NFT for rent:
;; - Verifies caller owns the NFT via SIP-009 get-owner?
;; - Escrows the NFT into this contract via SIP-009 transfer?
(define-public (offer-for-rent (nft <sip009-nft-trait>) (token-id uint) (price uint) (duration uint))
  (begin
    (if (<= price u0)
        (err ERR-INVALID-PRICE)
        (if (<= duration u0)
            (err ERR-INVALID-DURATION)
            (let ((existing (map-get? rentals token-id)))
              (match existing
                listing
                  (if (is-none (get renter listing))
                      (err ERR-ALREADY-LISTED)
                      (err ERR-ALREADY-RENTED))
                ;; New listing path
                (let (
                      (owner-opt (unwrap! (contract-call? nft get-owner? token-id) (err ERR-NOT-OWNER)))
                    )
                  ;; Ensure tx-sender currently owns the NFT
                  (match owner-opt
                    owner-principal
                      (if (is-eq owner-principal tx-sender)
                          (let (
                                ;; Escrow NFT to this contract (.lapo) must succeed
                                (escrow-res (contract-call? nft transfer? token-id tx-sender .lapo))
                               )
                            (match escrow-res
                              escrow-ok
                                (begin
                                  (map-set rentals token-id
                                    {
                                      nft-owner: tx-sender,
                                      renter: none,
                                      expiry: u0,
                                      price: price,
                                      duration: duration
                                    })
                                  (ok true))
                              escrow-err
                                (err ERR-ESCROW-FAILED)))
                          (err ERR-NOT-OWNER))
                    (err ERR-NOT-OWNER)))))))))

;; Rent a listed NFT:
;; - Confirms listing exists and is available
;; - Verifies the NFT is still in escrow with this contract
;; - Transfers STX to the owner atomically with state update
(define-public (rent (nft <sip009-nft-trait>) (token-id uint))
  (let ((opt-listing (map-get? rentals token-id)))
    (match opt-listing
      listing
        (if (is-none (get renter listing))
            (let (
                  (price (get price listing))
                  (owner (get nft-owner listing))
                  (duration (get duration listing))
                 )
              ;; Verify the NFT remains escrowed in this contract before taking payment
              (let (
                    (escrow-owner-opt (unwrap! (contract-call? nft get-owner? token-id) (err ERR-NOT-ESCROWED)))
                   )
                (match escrow-owner-opt
                  escrow-owner
                    (if (is-eq escrow-owner .lapo)
                        ;; Transfer must succeed or we abort, so state and payment are atomic.
                        (match (stx-transfer? price tx-sender owner)
                          transfer-ok
                            (begin
                              (map-set rentals token-id
                                {
                                  nft-owner: owner,
                                  renter: (some tx-sender),
                                  expiry: (+ stacks-block-height duration),
                                  price: price,
                                  duration: duration
                                })
                              (ok true))
                          transfer-err
                            (err ERR-STX-TRANSFER-FAILED))
                        (err ERR-NOT-ESCROWED))
                  (err ERR-NOT-ESCROWED))))
            (err ERR-ALREADY-RENTED))
      (err ERR-NOT-FOUND))))