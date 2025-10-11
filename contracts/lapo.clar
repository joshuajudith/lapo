(define-trait sip009-nft-trait
  (
    ;; SIP-009 core surface we rely on
    (transfer? (uint principal principal) (response bool uint))
    (get-owner? (uint) (response (optional principal) uint))
  )
)

;; Original error constants
(define-constant ERR-NOT-FOUND u100)
(define-constant ERR-ALREADY-LISTED u101)
(define-constant ERR-INVALID-PRICE u102)
(define-constant ERR-INVALID-DURATION u103)
(define-constant ERR-ALREADY-RENTED u104)
(define-constant ERR-NOT-OWNER u105)
(define-constant ERR-ESCROW-FAILED u106)
(define-constant ERR-NOT-ESCROWED u107)
(define-constant ERR-STX-TRANSFER-FAILED u108)

;; New error constants for enhanced functionality
(define-constant ERR-RENTAL-NOT-EXPIRED u109)
(define-constant ERR-NOT-RENTER u110)
(define-constant ERR-RETURN-FAILED u111)
(define-constant ERR-UNAUTHORIZED u112)
(define-constant ERR-CONTRACT-PAUSED u113)
(define-constant ERR-INVALID-STATE u114)

;; Security and admin variables
(define-data-var contract-admin principal tx-sender)
(define-data-var contract-paused bool false)
(define-data-var reentrancy-guard bool false)

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

;; Security helper functions
(define-private (check-reentrancy)
  (if (var-get reentrancy-guard)
      (err ERR-INVALID-STATE)
      (begin
        (var-set reentrancy-guard true)
        (ok true))))

(define-private (clear-reentrancy)
  (var-set reentrancy-guard false))

;; Original offer-for-rent function (maintained for backward compatibility)
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
                                (escrow-res (contract-call? nft transfer? token-id tx-sender (as-contract tx-sender)))
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

;; Enhanced offer-for-rent with security checks
(define-public (offer-for-rent-secure (nft <sip009-nft-trait>) (token-id uint) (price uint) (duration uint))
  (begin
    ;; Check if contract is paused
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    
    ;; Reentrancy protection
    (unwrap! (check-reentrancy) (err ERR-INVALID-STATE))
    
    ;; Input validation with reasonable limits
    (asserts! (and (> price u0) (<= price u1000000000000)) (err ERR-INVALID-PRICE))
    (asserts! (and (> duration u0) (<= duration u52560)) (err ERR-INVALID-DURATION)) ;; Max ~1 year
    
    (let ((result 
      (match (map-get? rentals token-id)
        existing-listing
          ;; Enhanced state validation
          (match (get renter existing-listing)
            current-renter
              ;; Check if rental is actually expired
              (if (>= stacks-block-height (get expiry existing-listing))
                  (err ERR-INVALID-STATE) ;; Should clean up expired rentals first
                  (err ERR-ALREADY-RENTED))
            (err ERR-ALREADY-LISTED))
        ;; New listing path with enhanced validation
        (let ((owner-result (contract-call? nft get-owner? token-id)))
          (match owner-result
            owner-response
              (match owner-response
                owner-principal
                  (if (is-eq owner-principal tx-sender)
                      ;; Verify NFT transfer with better error handling
                      (match (contract-call? nft transfer? token-id tx-sender (as-contract tx-sender))
                        escrow-success
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
                        escrow-error
                          (err ERR-ESCROW-FAILED))
                      (err ERR-NOT-OWNER))
                (err ERR-NOT-OWNER))
            query-error
              (err ERR-NOT-OWNER))))))
      
      ;; Clear reentrancy guard before returning
      (clear-reentrancy)
      result)))

;; Original rent function (maintained for backward compatibility)
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
                    (if (is-eq escrow-owner (as-contract tx-sender))
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

;; Enhanced rent function with security checks
(define-public (rent-secure (nft <sip009-nft-trait>) (token-id uint))
  (begin
    ;; Check if contract is paused
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    
    ;; Reentrancy protection
    (unwrap! (check-reentrancy) (err ERR-INVALID-STATE))
    
    (let ((result
      (match (map-get? rentals token-id)
        listing
          (if (is-none (get renter listing))
              (let ((price (get price listing))
                    (owner (get nft-owner listing))
                    (duration (get duration listing)))
                
                ;; Verify escrow state before payment
                (match (contract-call? nft get-owner? token-id)
                  owner-response
                    (match owner-response
                      escrow-owner
                        (if (is-eq escrow-owner (as-contract tx-sender))
                            ;; Atomic payment and state update
                            (match (stx-transfer? price tx-sender owner)
                              payment-success
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
                              payment-error
                                (err ERR-STX-TRANSFER-FAILED))
                            (err ERR-NOT-ESCROWED))
                      (err ERR-NOT-ESCROWED))
                  query-error
                    (err ERR-NOT-ESCROWED)))
              (err ERR-ALREADY-RENTED))
        (err ERR-NOT-FOUND))))
      
      ;; Clear reentrancy guard
      (clear-reentrancy)
      result)))

;; NEW FUNCTIONALITY: Return NFT after rental expires - callable by anyone
(define-public (return-expired-nft (nft <sip009-nft-trait>) (token-id uint))
  (let ((opt-listing (map-get? rentals token-id)))
    (match opt-listing
      listing
        (match (get renter listing)
          renter-principal
            (if (>= stacks-block-height (get expiry listing))
                ;; Rental has expired, return to original owner
                (match (contract-call? nft transfer? token-id (as-contract tx-sender) (get nft-owner listing))
                  transfer-ok
                    (begin
                      ;; Clear the rental listing
                      (map-delete rentals token-id)
                      (ok true))
                  transfer-err
                    (err ERR-RETURN-FAILED))
                (err ERR-RENTAL-NOT-EXPIRED))
          ;; No renter means it's just listed, owner can withdraw
          (if (is-eq tx-sender (get nft-owner listing))
              (match (contract-call? nft transfer? token-id (as-contract tx-sender) (get nft-owner listing))
                transfer-ok
                  (begin
                    (map-delete rentals token-id)
                    (ok true))
                transfer-err
                  (err ERR-RETURN-FAILED))
              (err ERR-NOT-OWNER)))
      (err ERR-NOT-FOUND))))

;; NEW FUNCTIONALITY: Early return by renter (optional feature for flexibility)
(define-public (early-return (nft <sip009-nft-trait>) (token-id uint))
  (let ((opt-listing (map-get? rentals token-id)))
    (match opt-listing
      listing
        (match (get renter listing)
          renter-principal
            (if (is-eq tx-sender renter-principal)
                (match (contract-call? nft transfer? token-id (as-contract tx-sender) (get nft-owner listing))
                  transfer-ok
                    (begin
                      (map-delete rentals token-id)
                      (ok true))
                  transfer-err
                    (err ERR-RETURN-FAILED))
                (err ERR-NOT-RENTER))
          (err ERR-NOT-FOUND))
      (err ERR-NOT-FOUND))))

;; Admin functions for emergency management
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) (err ERR-UNAUTHORIZED))
    (var-set contract-paused true)
    (ok true)))

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) (err ERR-UNAUTHORIZED))
    (var-set contract-paused false)
    (ok true)))

;; Transfer admin rights
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) (err ERR-UNAUTHORIZED))
    (var-set contract-admin new-admin)
    (ok true)))

;; Helper function to check if rental is active and not expired
(define-read-only (is-rental-active (token-id uint))
  (match (map-get? rentals token-id)
    listing
      (match (get renter listing)
        renter-principal
          (< stacks-block-height (get expiry listing))
        false)
    false))

;; Get rental details (useful for frontend)
(define-read-only (get-rental-info (token-id uint))
  (map-get? rentals token-id))

;; Read-only functions for security status
(define-read-only (get-contract-status)
  {
    admin: (var-get contract-admin),
    paused: (var-get contract-paused),
    reentrancy-active: (var-get reentrancy-guard)
  })

;; Get contract admin
(define-read-only (get-admin)
  (var-get contract-admin))

;; Check if contract is paused
(define-read-only (is-paused)
  (var-get contract-paused))
