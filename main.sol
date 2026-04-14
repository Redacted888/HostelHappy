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
        uint40 checkInDay; // days since Unix epoch (UTC)
        uint40 checkOutDay; // exclusive
        uint16 guests;
        bytes32 offchainPaymentRef;
        BookingState state;
        uint64 createdAt;
    }

    mapping(bytes32 => Host) public hosts;
    mapping(bytes32 => mapping(uint32 => Room)) public rooms;
    mapping(bytes32 => Booking) public bookings;

    constructor() {
        OWNER = msg.sender;
    }

    receive() external payable {
        revert EtherNotAccepted();
    }

    fallback() external payable {
        revert EtherNotAccepted();
    }

    // ============
    // Admin
    // ============
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PauseSet(value);
    }

    // ============
    // Host identity + profile
    // ============
    function computeHostId(address host, bytes32 profileHash) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_HOST_SALT, host, profileHash));
    }

    function registerHost(bytes32 profileHash) external whenNotPaused returns (bytes32 hostId) {
        if (profileHash == bytes32(0)) revert BadInput();

        hostId = computeHostId(msg.sender, profileHash);
        if (hosts[hostId].host != address(0)) revert AlreadyExists();

        hosts[hostId] = Host({host: msg.sender, profileHash: profileHash, active: true, roomCount: 0});
        emit HostelRegistered(hostId, msg.sender, profileHash);
    }

    function updateHostProfile(bytes32 hostId, bytes32 newProfileHash) external whenNotPaused {
        Host storage h = hosts[hostId];
        if (h.host == address(0)) revert NotFound();
        if (h.host != msg.sender) revert NotHost();
        if (newProfileHash == bytes32(0)) revert BadInput();

        h.profileHash = newProfileHash;
        emit HostelProfileUpdated(hostId, newProfileHash);
    }

    function setHostActive(bytes32 hostId, bool active_) external whenNotPaused {
        Host storage h = hosts[hostId];
        if (h.host == address(0)) revert NotFound();
        if (h.host != msg.sender) revert NotHost();

        h.active = active_;
        emit HostelActiveSet(hostId, active_);
    }

    // ============
    // Rooms
    // ============
    function upsertRoom(
        bytes32 hostId,
        uint32 roomNo,
        uint32 nightlyPriceWei,
        uint16 maxGuests,
        bool active_
    ) external whenNotPaused {
        Host storage h = hosts[hostId];
        if (h.host == address(0)) revert NotFound();
        if (!h.active) revert NotActive();
        if (h.host != msg.sender) revert NotHost();

        if (roomNo == 0) revert BadInput();
        if (maxGuests == 0) revert BadInput();

        Room storage r = rooms[hostId][roomNo];
        if (!r.exists) {
            h.roomCount += 1;
            r.exists = true;
        }

        r.nightlyPriceWei = nightlyPriceWei;
        r.maxGuests = maxGuests;
        r.active = active_;

        emit RoomUpserted(hostId, roomNo, nightlyPriceWei, maxGuests);
        emit RoomActiveSet(hostId, roomNo, active_);
    }

    function setRoomActive(bytes32 hostId, uint32 roomNo, bool active_) external whenNotPaused {
        Host storage h = hosts[hostId];
        if (h.host == address(0)) revert NotFound();
        if (h.host != msg.sender) revert NotHost();

        Room storage r = rooms[hostId][roomNo];
        if (!r.exists) revert NotFound();

        r.active = active_;
        emit RoomActiveSet(hostId, roomNo, active_);
    }

    // ============
    // Bookings (no payments, no custody)
    // ============
    function computeBookingId(
        bytes32 hostId,
        uint32 roomNo,
        address booker,
        uint40 checkInDay,
        uint40 checkOutDay,
        uint16 guests,
        bytes32 offchainPaymentRef,
        uint64 createdAt
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                _BOOKING_SALT,
                hostId,
                roomNo,
                booker,
                checkInDay,
                checkOutDay,
                guests,
                offchainPaymentRef,
                createdAt
            )
        );
    }

    function requestBooking(
        bytes32 hostId,
        uint32 roomNo,
        uint40 checkInDay,
        uint40 checkOutDay,
        uint16 guests,
        bytes32 offchainPaymentRef
    ) external whenNotPaused returns (bytes32 bookingId) {
        Host storage h = hosts[hostId];
        if (h.host == address(0)) revert NotFound();
        if (!h.active) revert NotActive();

        Room storage r = rooms[hostId][roomNo];
        if (!r.exists) revert NotFound();
        if (!r.active) revert NotActive();

        if (guests == 0 || guests > r.maxGuests) revert BadInput();
        if (checkOutDay <= checkInDay) revert BadInput();
        if (offchainPaymentRef == bytes32(0)) revert BadInput();

        uint64 createdAt = uint64(block.timestamp);
        bookingId = computeBookingId(
            hostId,
            roomNo,
            msg.sender,
            checkInDay,
            checkOutDay,
            guests,
            offchainPaymentRef,
            createdAt
        );

        if (bookings[bookingId].state != BookingState.None) revert AlreadyExists();

        bookings[bookingId] = Booking({
            hostId: hostId,
            roomNo: roomNo,
            booker: msg.sender,
            checkInDay: checkInDay,
            checkOutDay: checkOutDay,
            guests: guests,
            offchainPaymentRef: offchainPaymentRef,
            state: BookingState.Requested,
            createdAt: createdAt
        });

        emit BookingRequested(
            bookingId,
            hostId,
            roomNo,
            msg.sender,
            checkInDay,
            checkOutDay,
            guests,
            offchainPaymentRef
        );
    }

    function hostDecideBooking(bytes32 bookingId, bool accept, bytes32 noteHash) external whenNotPaused {
        Booking storage b = bookings[bookingId];
        if (b.state == BookingState.None) revert NotFound();

        Host storage h = hosts[b.hostId];
        if (h.host == address(0)) revert NotFound();
        if (h.host != msg.sender) revert NotHost();

        if (b.state != BookingState.Requested) revert StateMismatch();

        b.state = accept ? BookingState.Accepted : BookingState.Rejected;
        emit BookingHostDecision(bookingId, accept, noteHash);
    }

    function checkIn(bytes32 bookingId, bytes32 proofHash) external whenNotPaused {
        Booking storage b = bookings[bookingId];
        if (b.state == BookingState.None) revert NotFound();
        if (b.booker != msg.sender) revert NotBooker();
        if (b.state != BookingState.Accepted) revert StateMismatch();
        if (proofHash == bytes32(0)) revert BadInput();

        b.state = BookingState.CheckedIn;
        emit BookingCheckedIn(bookingId, proofHash);
    }

    function checkOut(bytes32 bookingId, bytes32 proofHash) external whenNotPaused {
        Booking storage b = bookings[bookingId];
        if (b.state == BookingState.None) revert NotFound();
        if (b.booker != msg.sender) revert NotBooker();
        if (b.state != BookingState.CheckedIn) revert StateMismatch();
        if (proofHash == bytes32(0)) revert BadInput();

        b.state = BookingState.CheckedOut;
        emit BookingCheckedOut(bookingId, proofHash);
    }

    function cancelBooking(bytes32 bookingId, bytes32 reasonHash) external whenNotPaused {
        Booking storage b = bookings[bookingId];
        if (b.state == BookingState.None) revert NotFound();
        if (b.booker != msg.sender) revert NotBooker();

        if (b.state != BookingState.Requested && b.state != BookingState.Accepted) revert StateMismatch();

        b.state = BookingState.Cancelled;
        emit BookingCancelled(bookingId, reasonHash);
    }

    // ============
    // View helpers
    // ============
    function getRoom(bytes32 hostId, uint32 roomNo) external view returns (Room memory) {
        Room memory r = rooms[hostId][roomNo];
        if (!r.exists) revert NotFound();
        return r;
    }

    function getBooking(bytes32 bookingId) external view returns (Booking memory) {
        Booking memory b = bookings[bookingId];
        if (b.state == BookingState.None) revert NotFound();
        return b;
    }
}
