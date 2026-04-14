// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    HostelHappy is a lightweight onchain bulletin-board for hostel listings and bookings.
    It intentionally does not custody Ether or tokens (receive/fallback revert), so it is not a vault.
*/

contract HostelHappy {
    // ============
    // Custom errors
    // ============
    error NotOwner();
    error Paused();
    error BadInput();
    error NotFound();
    error NotActive();
    error AlreadyExists();
    error NotBooker();
    error NotHost();
    error StateMismatch();
    error EtherNotAccepted();

    // ============
    // Events
    // ============
    event PauseSet(bool paused);

    event HostelRegistered(bytes32 indexed hostId, address indexed host, bytes32 profileHash);
    event HostelProfileUpdated(bytes32 indexed hostId, bytes32 newProfileHash);
    event HostelActiveSet(bytes32 indexed hostId, bool active);

    event RoomUpserted(bytes32 indexed hostId, uint32 indexed roomNo, uint32 nightlyPriceWei, uint16 maxGuests);
    event RoomActiveSet(bytes32 indexed hostId, uint32 indexed roomNo, bool active);

    event BookingRequested(
        bytes32 indexed bookingId,
        bytes32 indexed hostId,
        uint32 indexed roomNo,
        address booker,
        uint40 checkInDay,
        uint40 checkOutDay,
        uint16 guests,
        bytes32 offchainPaymentRef
    );

    event BookingHostDecision(bytes32 indexed bookingId, bool accepted, bytes32 noteHash);
    event BookingCheckedIn(bytes32 indexed bookingId, bytes32 proofHash);
    event BookingCheckedOut(bytes32 indexed bookingId, bytes32 proofHash);
    event BookingCancelled(bytes32 indexed bookingId, bytes32 reasonHash);

    // ============
    // Owner + safety
    // ============
    address public immutable OWNER;
    bool public paused;

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ============
    // Domain constants (random-looking, not externally meaningful)
    // ============
    bytes32 private constant _HOST_SALT =
        hex"5a8c3f0e8a1d6d4c1b9f11f6c7b9c6a1d5d7f3b0a2c4e9b1d8e6a0c9f1b3a7d2";
    bytes32 private constant _BOOKING_SALT =
        hex"c2d17f0a9b38e6d45a77b1c0f8a61d2e3c4b5a69788796a5b4c3d2e1f0a9b8c7";

    // ============
    // Data model
    // ============
    struct Host {
        address host;
        bytes32 profileHash;
        bool active;
        uint32 roomCount;
    }

    struct Room {
        uint32 nightlyPriceWei; // informational; no payment is accepted by this contract
        uint16 maxGuests;
        bool active;
        bool exists;
    }

    enum BookingState {
        None,
        Requested,
        Accepted,
        Rejected,
        CheckedIn,
        CheckedOut,
        Cancelled
    }

    struct Booking {
        bytes32 hostId;
        uint32 roomNo;
        address booker;
