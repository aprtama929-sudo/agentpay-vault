// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AgentPayVault — scoped payment mandates for AI agents
/// @notice A principal (human, merchant, or another program) creates an on-chain
///         *mandate* that authorizes one agent address to spend a specific ERC-20
///         (on QDay Aevum: tUSD8) under hard, contract-enforced limits:
///
///           - a per-transaction cap,
///           - a total budget cap,
///           - an expiry timestamp (a "session" window),
///           - an optional payee allowlist.
///
///         The agent can pay freely *inside* those bounds and provably cannot
///         exceed them. The owner can revoke the mandate at any time and reclaim
///         every unspent token. Every state change emits an event, so the full
///         life of a mandate is a verifiable on-chain audit trail.
///
/// @dev    Design goals: least privilege by construction, no admin keys, no
///         upgradeability, no external dependencies. The vault is token-agnostic;
///         it never holds funds outside of mandate accounting (`funded - spent`
///         per mandate is always fully backed by the vault's token balance).

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract AgentPayVault {
    // ------------------------------------------------------------------ types

    struct Mandate {
        address owner; // principal who created (and funds) the mandate
        address agent; // the only address allowed to execute payments
        address token; // ERC-20 being spent (tUSD8 on Aevum)
        uint256 perTxCap; // max amount per single payment
        uint256 totalBudget; // max cumulative amount over the mandate's life
        uint256 funded; // tokens actually deposited into the vault
        uint256 spent; // tokens already paid out
        uint64 expiresAt; // unix timestamp; payments after this revert
        bool allowAnyPayee; // if false, payees must be allowlisted
        bool revoked; // once true, the mandate is dead forever
    }

    // ------------------------------------------------------------------ state

    uint256 public mandateCount;
    mapping(uint256 => Mandate) private _mandates;
    mapping(uint256 => mapping(address => bool)) private _payeeAllowed;

    uint256 private _reentrancyLock = 1;

    // ----------------------------------------------------------------- events

    event MandateCreated(
        uint256 indexed id,
        address indexed owner,
        address indexed agent,
        address token,
        uint256 perTxCap,
        uint256 totalBudget,
        uint64 expiresAt,
        bool allowAnyPayee
    );
    event MandateFunded(uint256 indexed id, address indexed from, uint256 amount, uint256 fundedTotal);
    event PayeeAllowedSet(uint256 indexed id, address indexed payee, bool allowed);
    event PaymentExecuted(
        uint256 indexed id,
        address indexed agent,
        address indexed payee,
        uint256 amount,
        string memo,
        uint256 spentTotal,
        uint256 remainingBudget
    );
    event MandateRevoked(uint256 indexed id, address indexed owner, uint256 refunded);
    event MandateClosedExpired(uint256 indexed id, address indexed owner, uint256 refunded);

    // ----------------------------------------------------------------- errors

    error NotOwner(uint256 id);
    error NotAgent(uint256 id);
    error MandateRevokedError(uint256 id);
    error MandateExpired(uint256 id);
    error MandateNotExpired(uint256 id);
    error ZeroAddress();
    error InvalidLimits();
    error OverPerTxCap(uint256 amount, uint256 cap);
    error OverBudget(uint256 amount, uint256 remaining);
    error InsufficientFunds(uint256 amount, uint256 available);
    error PayeeNotAllowed(uint256 id, address payee);
    error TransferFailed();
    error ReentrantCall();

    // -------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert ReentrantCall();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    modifier onlyOwner(uint256 id) {
        if (msg.sender != _mandates[id].owner) revert NotOwner(id);
        _;
    }

    // ------------------------------------------------------------ token utils

    /// @dev Handles ERC-20s that return true, return nothing, or return false.
    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // -------------------------------------------------------------- lifecycle

    /// @notice Create a payment mandate for `agent`. Does not move any tokens;
    ///         call `fund` afterwards (the owner must `approve` this vault first).
    /// @param agent         The agent address that will execute payments.
    /// @param token         ERC-20 to spend (tUSD8 on QDay Aevum).
    /// @param perTxCap      Maximum amount per single payment (> 0).
    /// @param totalBudget   Maximum cumulative spend (> 0, >= perTxCap).
    /// @param expiresAt     Unix timestamp after which payments revert (must be future).
    /// @param allowAnyPayee If false, payees must be added via `setPayeeAllowed`.
    /// @return id           The new mandate id.
    function createMandate(
        address agent,
        address token,
        uint256 perTxCap,
        uint256 totalBudget,
        uint64 expiresAt,
        bool allowAnyPayee
    ) external returns (uint256 id) {
        if (agent == address(0) || token == address(0)) revert ZeroAddress();
        if (perTxCap == 0 || totalBudget < perTxCap) revert InvalidLimits();
        if (expiresAt <= block.timestamp) revert InvalidLimits();

        id = ++mandateCount;
        _mandates[id] = Mandate({
            owner: msg.sender,
            agent: agent,
            token: token,
            perTxCap: perTxCap,
            totalBudget: totalBudget,
            funded: 0,
            spent: 0,
            expiresAt: expiresAt,
            allowAnyPayee: allowAnyPayee,
            revoked: false
        });

        emit MandateCreated(id, msg.sender, agent, token, perTxCap, totalBudget, expiresAt, allowAnyPayee);
    }

    /// @notice Deposit tokens into a mandate. Pulls from the mandate owner via
    ///         `transferFrom` (approve this contract first). Funding more than
    ///         the budget is allowed but pointless: payments are still capped
    ///         by `totalBudget`, and the excess comes back on revoke/close.
    function fund(uint256 id, uint256 amount) external onlyOwner(id) nonReentrant {
        Mandate storage m = _mandates[id];
        if (m.revoked) revert MandateRevokedError(id);
        _safeTransferFrom(IERC20(m.token), msg.sender, address(this), amount);
        m.funded += amount;
        emit MandateFunded(id, msg.sender, amount, m.funded);
    }

    /// @notice Add or remove a payee on the mandate allowlist (owner only).
    ///         Irrelevant when the mandate was created with `allowAnyPayee`.
    function setPayeeAllowed(uint256 id, address payee, bool allowed) external onlyOwner(id) {
        if (payee == address(0)) revert ZeroAddress();
        _payeeAllowed[id][payee] = allowed;
        emit PayeeAllowedSet(id, payee, allowed);
    }

    /// @notice Execute a payment. Callable ONLY by the mandate's agent.
    ///         Enforces, in order: not revoked, not expired, per-tx cap,
    ///         total budget, deposited funds, payee allowlist.
    /// @param memo Free-text reference (invoice id, order hash, …) stored
    ///             permanently in the PaymentExecuted event for auditability.
    function pay(uint256 id, address payee, uint256 amount, string calldata memo) external nonReentrant {
        Mandate storage m = _mandates[id];
        if (msg.sender != m.agent) revert NotAgent(id);
        if (m.revoked) revert MandateRevokedError(id);
        if (block.timestamp > m.expiresAt) revert MandateExpired(id);
        if (payee == address(0)) revert ZeroAddress();
        if (amount > m.perTxCap) revert OverPerTxCap(amount, m.perTxCap);

        uint256 remainingBudget = m.totalBudget - m.spent;
        if (amount > remainingBudget) revert OverBudget(amount, remainingBudget);

        uint256 available = m.funded - m.spent;
        if (amount > available) revert InsufficientFunds(amount, available);

        if (!m.allowAnyPayee && !_payeeAllowed[id][payee]) revert PayeeNotAllowed(id, payee);

        // effects before interaction
        m.spent += amount;
        _safeTransfer(IERC20(m.token), payee, amount);

        emit PaymentExecuted(id, msg.sender, payee, amount, memo, m.spent, m.totalBudget - m.spent);
    }

    /// @notice Instantly revoke a mandate and reclaim all unspent funds.
    ///         Works before or after expiry; the mandate can never pay again.
    function revoke(uint256 id) external onlyOwner(id) nonReentrant {
        Mandate storage m = _mandates[id];
        if (m.revoked) revert MandateRevokedError(id);
        m.revoked = true;

        uint256 refund = m.funded - m.spent;
        m.funded = m.spent; // keep accounting exact: nothing left to claim
        if (refund > 0) _safeTransfer(IERC20(m.token), m.owner, refund);

        emit MandateRevoked(id, m.owner, refund);
    }

    /// @notice After expiry, anyone may close the mandate; unspent funds are
    ///         returned to the owner. (The owner can also simply `revoke`.)
    function closeExpired(uint256 id) external nonReentrant {
        Mandate storage m = _mandates[id];
        if (m.revoked) revert MandateRevokedError(id);
        if (block.timestamp <= m.expiresAt) revert MandateNotExpired(id);
        m.revoked = true;

        uint256 refund = m.funded - m.spent;
        m.funded = m.spent;
        if (refund > 0) _safeTransfer(IERC20(m.token), m.owner, refund);

        emit MandateClosedExpired(id, m.owner, refund);
    }

    // ------------------------------------------------------------------ views

    function getMandate(uint256 id) external view returns (Mandate memory) {
        return _mandates[id];
    }

    function isPayeeAllowed(uint256 id, address payee) external view returns (bool) {
        Mandate storage m = _mandates[id];
        return m.allowAnyPayee || _payeeAllowed[id][payee];
    }

    /// @notice Spendable amount right now = min(remaining budget, deposited funds),
    ///         or 0 when revoked/expired. What an agent UI would poll before paying.
    function spendable(uint256 id) external view returns (uint256) {
        Mandate storage m = _mandates[id];
        if (m.revoked || block.timestamp > m.expiresAt) return 0;
        uint256 remainingBudget = m.totalBudget - m.spent;
        uint256 available = m.funded - m.spent;
        return remainingBudget < available ? remainingBudget : available;
    }
}
