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
